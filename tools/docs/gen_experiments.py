"""Generate the experiment pages: settings reference, changelog, registry.

Run by mkdocs-gen-files on every build, so the pages always reflect the
checked-out ``sphinx-asr`` submodule and its git history. Nothing generated
here is committed.

Pages written (under ``experiments/`` in the build):

* ``settings.md``   every key of ``experiment.yml.template``, each
  ``corpus/*/experiment.yml.template`` and each ``corpus/*/corpus.yml``,
  with its default and meaning (YAML comment first, then a code-derived
  description, see ``EXPERIMENT_MEANINGS`` and ``CORPUS_MEANINGS``).
* ``changelog.md``  ``git -C sphinx-asr log`` over the settings-relevant
  paths: how code progress on experiment settings is tracked.
* ``registry.md``   one row per ``experiments/*/experiment.yml`` found
  under ``$SPHINX_EXPERIMENTS_DIR`` (default ``sphinx-asr/experiments``),
  plus ``results.yml`` (commit, wer, ser) when present.

Parsing is defensive: a malformed experiment is listed as unreadable and
never fails the build.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
SPHINX_DIR = REPO_ROOT / "sphinx-asr"
OUT_DIR = "experiments"

#: Paths (relative to sphinx-asr/) whose history is the settings changelog.
SETTINGS_PATHSPECS = (
    "experiment.yml.template",
    ":(glob)corpus/*/*.yml",
    ":(glob)corpus/*/experiment.yml.template",
    "scripts/lib/config.py",
    "scripts/train.py",
    "scripts/setup.py",
)

#: Meaning of experiment.yml keys, derived from reading the code. Keys are
#: dotted paths; ``*`` stands for any list index.
EXPERIMENT_MEANINGS: dict[str, str] = {
    "name": "Free-text experiment name. Metadata only; no script reads it.",
    "author": "Free-text author. Metadata only; no script reads it.",
    "train.corpora": "List of training corpora. Each entry needs `name` plus `split` or `splits` (`scripts/lib/config.py` `validate_experiment`).",
    "train.corpora.*.name": "Corpus directory under `corpus/`; selects `corpus/<name>/corpus.yml` and the adapter `scripts/corpus/<name>.py`.",
    "train.corpora.*.split": "Single split name; must exist under `splits:` in the corpus.yml (`_validate_split`).",
    "train.corpora.*.splits": "List of split names; each becomes one training entry (`load_experiment`).",
    "train.dict": "Optional dictionary path relative to SPHINX_ROOT; overrides the first training corpus's `dict` (`scripts/setup.py` `_resolve_dict_path`).",
    "decode.corpus.name": "Corpus used for decoding/scoring.",
    "decode.corpus.split": "Split decoded and scored for WER.",
    "decode.lm": "Optional LM path relative to SPHINX_ROOT; overrides the decode corpus's `lm` (`config.py` `_resolve_lm_path`).",
    "pipeline.mllt_init": "MLLT initialisation: `eye` (identity, default), `random`, or an integer seed (`scripts/train.py` `resolve_mllt_seed`).",
    "sphinxtrain": "Overrides spliced into the vendor `sphinx_train.cfg` by `config.py` `_apply_overrides`. Keys absent from the vendor template are dropped silently (review finding SA-6).",
    "sphinxtrain.CFG_HMM_TYPE": "Acoustic model type: `.cont.` (continuous), `.semi.` (semi-continuous) or `.ptm.`.",
    "sphinxtrain.CFG_STATESPERHMM": "Emitting states per phone HMM.",
    "sphinxtrain.CFG_SKIPSTATE": "Allow skip transitions between HMM states.",
    "sphinxtrain.CFG_INITIAL_NUM_DENSITIES": "Gaussians per state at the start of context-dependent training.",
    "sphinxtrain.CFG_FINAL_NUM_DENSITIES": "Gaussians per state after mixture splitting.",
    "sphinxtrain.CFG_N_TIED_STATES": "Number of tied states (senones) after decision-tree tying.",
    "sphinxtrain.CFG_LDA_MLLT": "Train an LDA/MLLT feature transform (`yes`/`no`).",
    "sphinxtrain.CFG_LDA_DIMENSION": "Output dimension of the LDA/MLLT transform.",
    "sphinxtrain.CFG_CONVERGENCE_RATIO": "Baum-Welch convergence threshold on the likelihood improvement ratio.",
    "sphinxtrain.CFG_NPART": "Number of parallel Baum-Welch parts submitted through the queue.",
    "sphinxtrain.CFG_QUEUE_TYPE": "SphinxTrain queue backend (`Queue::POSIX` runs locally; `Queue::PBS` submits jobs).",
    "sphinxtrain.CFG_SVSPEC": "Sub-vector specification for semi-continuous models; also written to `feat.params` (`setup.py`).",
    "sphinxtrain.DEC_CFG_NPART": "Number of parallel decode parts.",
    "sphinxtrain.DEC_CFG_LANGUAGEWEIGHT": "Decoder language-model weight.",
    "sphinxtrain.DEC_CFG_BEAMWIDTH": "Decoder main beam width.",
    "sphinxtrain.DEC_CFG_WORDBEAM": "Decoder word-exit beam width.",
    "sphinxtrain.DEC_CFG_WORDPENALTY": "Decoder word insertion penalty.",
}

#: Meaning of corpus.yml keys, derived from reading the code.
CORPUS_MEANINGS: dict[str, str] = {
    "name": "Corpus identifier; `scripts/lm.py` loads the adapter `scripts/corpus/<name>.py` from it.",
    "audio_format": "Audio file extension; becomes `CFG_WAVFILE_EXTENSION` and selects the `sphinx_fe` input mode (`scripts/feats.py`).",
    "audio_type": "Input type for `sphinx_fe`: `nist`, `raw`, `mswav` or `sox` (`feats.py` `extract_one`); becomes `CFG_WAVFILE_TYPE`.",
    "sample_rate": "Sample rate in Hz; becomes `CFG_WAVFILE_SRATE` and `-samprate` for feature extraction.",
    "num_filt": "Mel filterbank size (`CFG_NUM_FILT`, `-nfilt`). Default 25.",
    "lo_filt": "Lowest filterbank edge in Hz (`CFG_LO_FILT`, `-lowerf`). Default 130.",
    "hi_filt": "Highest filterbank edge in Hz (`CFG_HI_FILT`, `-upperf`). Default 6800.",
    "cmn": "Cepstral mean normalisation mode (`CFG_CMN`). Default `live`.",
    "dict": "Pronunciation dictionary relative to the corpus directory.",
    "lm": "Default decode language model relative to the corpus directory.",
    "full_transcripts": "Transcript file used by `sphinx lm <corpus> --all` (`scripts/lm.py` `extract_text_from_full`).",
    "audio_dir": "Shared audio directory used when a split has no `audio:` key (`feats.py` `process_split`).",
    "fillers": "Map of transcript filler token to filler phone; added to the dictionary and filler file (`setup.py`).",
    "splits": "Named data splits; see the split table for this corpus.",
}

SECTION_BANNER_RE = re.compile(r"^#\s*[=\-#*]{4,}\s*$")
KEY_RE = re.compile(r"^(?P<indent>\s*)(?P<dash>-\s+)?(?P<key>[A-Za-z_][\w.\-]*|\"[^\"]+\")\s*:(?P<rest>.*)$")
COMMENTED_KEY_RE = re.compile(r"^(?P<indent>\s*)#\s*(?P<key>[A-Z][A-Z0-9_]+)\s*:\s*(?P<val>.*)$")


# ---------------------------------------------------------------------------
# YAML comment extraction
# ---------------------------------------------------------------------------


@dataclass
class KeyDoc:
    """Comment text and commented-out examples recovered from a YAML file.

    Attributes:
        comments: Dotted key path to the comment attached to it.
        commented_keys: Dotted key path to the example value of a key that
            only appears commented out (an optional setting).
    """

    comments: dict[str, str] = field(default_factory=dict)
    commented_keys: dict[str, str] = field(default_factory=dict)


def _strip_inline_comment(rest: str) -> tuple[str, str]:
    """Split ``value  # comment`` into value and comment, respecting quotes."""
    quote = None
    for i, ch in enumerate(rest):
        if ch in "\"'":
            if quote is None:
                quote = ch
            elif quote == ch:
                quote = None
        elif ch == "#" and quote is None and (i == 0 or rest[i - 1].isspace()):
            return rest[:i].strip(), rest[i + 1 :].strip()
    return rest.strip(), ""


def extract_key_docs(text: str) -> KeyDoc:
    """Recover per-key comments from YAML text.

    A comment block directly above a key (no blank line in between) and an
    inline ``# comment`` after the value are both attached to that key.
    Banner lines such as ``# ====`` and blocks separated by a blank line are
    ignored. Lines like ``# DEC_CFG_WORDBEAM: "1e-40"`` inside a mapping are
    recorded as optional, commented-out keys.

    Args:
        text: YAML source.

    Returns:
        The recovered :class:`KeyDoc`.
    """
    doc = KeyDoc()
    stack: list[tuple[int, str]] = []  # (indent, key)
    pending: list[str] = []
    list_index: dict[int, int] = {}

    def path_for(indent: int, key: str) -> str:
        while stack and stack[-1][0] >= indent:
            stack.pop()
        parts = [k for _, k in stack] + [key]
        return ".".join(parts)

    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            pending = []
            continue
        stripped = line.strip()
        if stripped.startswith("#"):
            ck = COMMENTED_KEY_RE.match(line)
            if ck and stack:
                indent = len(ck.group("indent"))
                parent = [k for i, k in stack if i < indent]
                key_path = ".".join(parent + [ck.group("key")])
                doc.commented_keys[key_path] = ck.group("val").strip()
                if pending:
                    doc.comments.setdefault(key_path, " ".join(pending))
                continue
            if SECTION_BANNER_RE.match(stripped):
                pending = []
                continue
            body = stripped.lstrip("#").strip()
            if body:
                pending.append(body)
            continue
        m = KEY_RE.match(line)
        if not m:
            pending = []
            continue
        indent = len(m.group("indent"))
        key = m.group("key").strip('"')
        if m.group("dash"):
            # "- name: x" starts a list item one level below the list key.
            item_indent = indent
            idx = list_index.get(item_indent, -1) + 1
            list_index[item_indent] = idx
            while stack and stack[-1][0] >= item_indent:
                stack.pop()
            stack.append((item_indent, "*"))
            indent = item_indent + len(m.group("dash"))
        value, inline = _strip_inline_comment(m.group("rest"))
        key_path = path_for(indent, key)
        comment = " ".join(pending + ([inline] if inline else []))
        if comment:
            doc.comments[key_path] = comment
        pending = []
        stack.append((indent, key))
    return doc


# ---------------------------------------------------------------------------
# Settings reference
# ---------------------------------------------------------------------------


#: Mappings shown as one row instead of one row per entry.
LEAF_MAPPINGS = frozenset({"fillers"})


def flatten(data: Any, prefix: str = "") -> list[tuple[str, Any]]:
    """Flatten nested YAML data into ``(dotted.key, leaf value)`` pairs.

    List indices are rendered as ``*`` so that keys line up with
    the meaning tables and comment paths. Lists of scalars, and the
    mappings in ``LEAF_MAPPINGS``, stay one leaf.
    """
    out: list[tuple[str, Any]] = []
    if isinstance(data, dict) and prefix in LEAF_MAPPINGS:
        out.append((prefix, data))
    elif isinstance(data, dict):
        if not data and prefix:
            out.append((prefix, {}))
        for k, v in data.items():
            out.extend(flatten(v, f"{prefix}.{k}" if prefix else str(k)))
    elif isinstance(data, list) and any(isinstance(x, (dict, list)) for x in data):
        for item in data:
            out.extend(flatten(item, f"{prefix}.*"))
    else:
        out.append((prefix, data))
    return out


def meaning_for(key: str, doc: KeyDoc, known_meanings: dict[str, str]) -> tuple[str, str]:
    """Return ``(meaning, origin)`` for a key.

    The YAML comment comes first; a code-derived description from
    ``known_meanings`` is appended when one exists.
    """
    comment = doc.comments.get(key, "")
    known = known_meanings.get(key, "")
    if comment and known:
        return f"{comment.rstrip('.')}. Code: {known}", "comment, code"
    if comment:
        return comment, "comment"
    if known:
        return known, "code"
    return "(undocumented)", "none"


def fmt_value(value: Any) -> str:
    """Render a YAML value for a markdown table cell."""
    if value is None:
        text = "null"
    elif isinstance(value, str):
        text = '""' if value == "" else value
    elif isinstance(value, (list, dict)):
        text = yaml.safe_dump(value, default_flow_style=True, width=10_000).strip()
    else:
        text = str(value)
    text = text.replace("|", "\\|").replace("`", "'")
    return f"`{text}`"


def cell(text: str) -> str:
    """Escape free text for a markdown table cell."""
    return text.replace("|", "\\|").replace("\n", " ")


def settings_table(
    path: Path, known_meanings: dict[str, str], skip_prefixes: tuple[str, ...] = ()
) -> list[str]:
    """Render the key/default/meaning table for one YAML settings file."""
    try:
        text = path.read_text(encoding="utf-8")
        data = yaml.safe_load(text) or {}
    except (OSError, yaml.YAMLError) as exc:
        return ['!!! failure "Could not parse"', "", f"    `{exc}`", ""]
    if not isinstance(data, dict):
        return ["(not a mapping)", ""]
    doc = extract_key_docs(text)
    rows = ["| Key | Default | Meaning | Source |", "| --- | --- | --- | --- |"]
    seen = set()
    for key, value in flatten(data):
        if any(key == p or key.startswith(p + ".") for p in skip_prefixes):
            continue
        seen.add(key)
        meaning, origin = meaning_for(key, doc, known_meanings)
        rows.append(f"| `{key}` | {fmt_value(value)} | {cell(meaning)} | {origin} |")
    for key, example in sorted(doc.commented_keys.items()):
        if key in seen:
            continue
        meaning, origin = meaning_for(key, doc, known_meanings)
        rows.append(
            f"| `{key}` | unset (example {fmt_value(example.strip(chr(34)))}) | {cell(meaning)} | {origin} |"
        )
    rows.append("")
    return rows


def splits_table(path: Path) -> list[str]:
    """Render the split table of a corpus.yml."""
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        return []
    splits = data.get("splits") if isinstance(data, dict) else None
    if not isinstance(splits, dict) or not splits:
        return []
    cols: list[str] = []
    for cfg in splits.values():
        if isinstance(cfg, dict):
            for k in cfg:
                if k not in cols:
                    cols.append(k)
    rows = ["| Split | " + " | ".join(cols) + " |", "| --- |" + " --- |" * len(cols)]
    for name, cfg in splits.items():
        cfg = cfg if isinstance(cfg, dict) else {}
        rows.append(f"| `{name}` | " + " | ".join(cell(str(cfg.get(c, ""))) for c in cols) + " |")
    rows.append("")
    return rows


def settings_page(sphinx_dir: Path) -> str:
    """Render ``experiments/settings.md``."""
    lines = [
        "# Settings reference",
        "",
        "Generated at build time by `tools/docs/gen_experiments.py` from the",
        "checked-out `sphinx-asr` submodule. *Source* says where the meaning came",
        "from: `comment` is the YAML comment in the file itself, `code` is a",
        "description written from reading `sphinx-asr/scripts/` (kept in",
        "`EXPERIMENT_MEANINGS` / `CORPUS_MEANINGS` in the generator), `none` means nobody has documented it",
        "yet. Rows marked *unset* are commented out in the template: optional",
        "settings with an example value.",
        "",
        "How the files combine: `sphinx new` copies a template to",
        "`experiments/NNN/experiment.yml`; `sphinx setup` loads it, resolves every",
        "corpus through its `corpus.yml`, and writes `etc/sphinx_train.cfg` with",
        "the corpus values first and the `sphinxtrain:` overrides last",
        "(`sphinx-asr/scripts/lib/config.py`).",
        "",
    ]
    if not sphinx_dir.is_dir() or not any(sphinx_dir.iterdir()):
        lines += [
            '!!! warning "sphinx-asr submodule is empty"',
            "",
            "    Run `git submodule update --init` and rebuild.",
            "",
        ]
        return "\n".join(lines)
    top = sphinx_dir / "experiment.yml.template"
    lines += ["## Default experiment template", "", "File: `sphinx-asr/experiment.yml.template`", ""]
    lines += settings_table(top, EXPERIMENT_MEANINGS) if top.is_file() else ["(missing)", ""]
    for corpus_dir in sorted(p for p in (sphinx_dir / "corpus").glob("*") if p.is_dir()):
        name = corpus_dir.name
        lines += [f"## Corpus `{name}`", ""]
        cy = corpus_dir / "corpus.yml"
        if cy.is_file():
            lines += ["### corpus.yml", "", f"File: `sphinx-asr/corpus/{name}/corpus.yml`", ""]
            lines += settings_table(cy, CORPUS_MEANINGS, skip_prefixes=("splits",))
            st = splits_table(cy)
            if st:
                lines += ["#### Splits", ""] + st
        tmpl = corpus_dir / "experiment.yml.template"
        if tmpl.is_file():
            lines += [
                "### experiment.yml.template",
                "",
                f"File: `sphinx-asr/corpus/{name}/experiment.yml.template` (used by `sphinx new -t {name}`)",
                "",
            ]
            lines += settings_table(tmpl, EXPERIMENT_MEANINGS)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Settings changelog
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Commit:
    """One commit touching settings-relevant files."""

    sha: str
    date: str
    author: str
    subject: str
    files: tuple[str, ...]


def collect_changelog(sphinx_dir: Path, limit: int | None = None) -> list[Commit] | None:
    """Return commits touching ``SETTINGS_PATHSPECS``, newest first.

    Args:
        sphinx_dir: The sphinx-asr checkout.
        limit: Maximum number of commits, or ``None`` for all.

    Returns:
        The commits, or ``None`` when git history is unavailable.
    """
    if not (sphinx_dir / ".git").exists():
        return None
    cmd = ["git", "-C", str(sphinx_dir), "log", "--date=short", "--name-only",
           "--pretty=format:%x1e%h%x1f%ad%x1f%an%x1f%s"]
    if limit:
        cmd.append(f"-n{limit}")
    cmd += ["--", *SETTINGS_PATHSPECS]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    commits = []
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        header, _, rest = record.partition("\n")
        parts = header.split("\x1f")
        if len(parts) != 4:
            continue
        files = tuple(f for f in rest.splitlines() if f.strip())
        commits.append(Commit(parts[0], parts[1], parts[2], parts[3], files))
    return commits


def changelog_page(sphinx_dir: Path) -> str:
    """Render ``experiments/changelog.md``."""
    commits = collect_changelog(sphinx_dir)
    lines = [
        "# Settings changelog",
        "",
        "Every `sphinx-asr` commit that touched a file deciding experiment",
        "settings, newest first. Generated at build time from",
        "`git -C sphinx-asr log` over:",
        "",
    ]
    lines += [f"- `{p}`" for p in SETTINGS_PATHSPECS]
    lines += [
        "",
        "This is the record of how settings evolved in code. Compare a row's sha",
        "with the `commit` in an experiment's `results.yml` (see the",
        "[registry](registry.md)) to know which settings code produced a result.",
        "",
    ]
    if commits is None:
        lines += [
            '!!! warning "No git history"',
            "",
            "    `sphinx-asr` is not a git checkout here (missing submodule or a",
            "    shallow export). Run `git submodule update --init` and rebuild.",
            "",
        ]
        return "\n".join(lines)
    if not commits:
        lines += ["No commits touched the settings paths.", ""]
        return "\n".join(lines)
    lines += ["| Commit | Date | Author | Subject | Files |", "| --- | --- | --- | --- | --- |"]
    for c in commits:
        files = "<br>".join(f"`{f}`" for f in c.files)
        lines.append(f"| `{c.sha}` | {c.date} | {cell(c.author)} | {cell(c.subject)} | {files} |")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Experiment registry
# ---------------------------------------------------------------------------


@dataclass
class ExperimentRow:
    """One parsed experiment."""

    exp_id: str
    train: list[str]
    decode: str
    overrides: dict[str, Any]
    results: dict[str, Any] | None


@dataclass
class Registry:
    """Result of scanning an experiments directory."""

    directory: Path
    exists: bool
    rows: list[ExperimentRow] = field(default_factory=list)
    unreadable: list[tuple[str, str]] = field(default_factory=list)


def experiments_dir() -> Path:
    """Return the experiments directory from ``SPHINX_EXPERIMENTS_DIR``."""
    raw = os.environ.get("SPHINX_EXPERIMENTS_DIR", "sphinx-asr/experiments")
    path = Path(raw).expanduser()
    return path if path.is_absolute() else REPO_ROOT / path


def _train_entries(train: Any) -> list[str]:
    corpora = train.get("corpora") if isinstance(train, dict) else None
    if not isinstance(corpora, list):
        raise ValueError("train.corpora is not a list")
    out = []
    for entry in corpora:
        if not isinstance(entry, dict) or "name" not in entry:
            raise ValueError("train.corpora entry without a name")
        splits = entry.get("splits") or []
        if isinstance(splits, str):
            splits = [splits]
        if not isinstance(splits, list):
            raise ValueError("train.corpora[].splits is not a list")
        splits = list(splits)
        if "split" in entry:
            splits.append(entry["split"])
        out += [f"{entry['name']}:{s}" for s in splits] or [f"{entry['name']}:?"]
    return out


def parse_experiment(exp_yml: Path) -> ExperimentRow:
    """Parse one ``experiment.yml`` (and sibling ``results.yml``).

    Args:
        exp_yml: Path to the experiment file.

    Returns:
        The parsed row.

    Raises:
        ValueError: If the file is not valid YAML or lacks the train/decode
            structure that ``sphinx setup`` requires.
    """
    try:
        data = yaml.safe_load(exp_yml.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as exc:
        raise ValueError(f"cannot parse: {exc.__class__.__name__}") from exc
    if not isinstance(data, dict):
        raise ValueError("top level is not a mapping")
    train = _train_entries(data.get("train"))
    dec = data.get("decode")
    corpus = dec.get("corpus") if isinstance(dec, dict) else None
    if not isinstance(corpus, dict) or "name" not in corpus:
        raise ValueError("decode.corpus.name missing")
    decode = f"{corpus['name']}:{corpus.get('split', '?')}"
    overrides = data.get("sphinxtrain") or {}
    if not isinstance(overrides, dict):
        raise ValueError("sphinxtrain is not a mapping")
    results = None
    res_path = exp_yml.with_name("results.yml")
    if res_path.is_file():
        try:
            loaded = yaml.safe_load(res_path.read_text(encoding="utf-8"))
            results = loaded if isinstance(loaded, dict) else {"error": "results.yml is not a mapping"}
        except (OSError, UnicodeDecodeError, yaml.YAMLError):
            results = {"error": "results.yml unreadable"}
    return ExperimentRow(exp_yml.parent.name, train, decode, overrides, results)


def collect_registry(directory: Path) -> Registry:
    """Scan ``directory/*/experiment.yml`` without ever raising."""
    reg = Registry(directory=directory, exists=directory.is_dir())
    if not reg.exists:
        return reg
    for exp_yml in sorted(directory.glob("*/experiment.yml")):
        try:
            reg.rows.append(parse_experiment(exp_yml))
        except Exception as exc:  # noqa: BLE001 - never fail the build
            reg.unreadable.append((exp_yml.parent.name, str(exc)))
    return reg


def registry_page(reg: Registry) -> str:
    """Render ``experiments/registry.md``."""
    try:
        shown_dir = reg.directory.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        shown_dir = reg.directory.as_posix()
    lines = [
        "# Experiment registry",
        "",
        f"Scanned `{shown_dir}/*/experiment.yml` at build time (override with the",
        "`SPHINX_EXPERIMENTS_DIR` environment variable). Results come from a",
        "`results.yml` next to the experiment with the fields `commit`, `wer`",
        "and `ser`.",
        "",
    ]
    if not reg.rows and not reg.unreadable:
        lines += [
            '!!! info "No experiments found"',
            "",
            "    The registry is empty. `sphinx-asr/experiments/` is gitignored in the",
            "    submodule, so a fresh checkout has none; experiments live on the",
            "    machine that ran them (on the cluster, under `/srv/ivalice/`).",
            "",
            "    To populate this page, build the wiki with",
            "    `SPHINX_EXPERIMENTS_DIR=/path/to/experiments`, or create one with",
            "    `./sphinx.sh new` in `sphinx-asr/`. After a run, write",
            "    `results.yml` beside `experiment.yml`:",
            "",
            "    ```yaml",
            "    commit: 1aa0441   # sphinx-asr commit that produced the result",
            "    wer: 23.4         # word error rate, percent",
            "    ser: 61.0         # sentence error rate, percent",
            "    ```",
            "",
            "    Recording results is not automatic yet (review finding SA-12).",
            "",
        ]
        return "\n".join(lines)
    if reg.rows:
        lines += [
            "| Id | Train | Decode | sphinxtrain overrides | Commit | WER | SER |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        for r in reg.rows:
            ov = "<br>".join(f"`{k}={v}`" for k, v in r.overrides.items()) or "(none)"
            res = r.results or {}
            if "error" in res:
                commit, wer, ser = res["error"], "", ""
            else:
                commit = f"`{res['commit']}`" if res.get("commit") else "-"
                wer = str(res.get("wer", "-"))
                ser = str(res.get("ser", "-"))
            lines.append(
                f"| `{r.exp_id}` | {'<br>'.join(cell(t) for t in r.train)} | {cell(r.decode)} | {cell(ov)} | {cell(commit)} | {wer} | {ser} |"
            )
        lines.append("")
    if reg.unreadable:
        lines += ["## Unreadable", "", "| Id | Problem |", "| --- | --- |"]
        lines += [f"| `{i}` | {cell(p)} |" for i, p in reg.unreadable]
        lines.append("")
    return "\n".join(lines)


def index_page() -> str:
    """Render ``experiments/index.md``."""
    return "\n".join([
        "# Experiments",
        "",
        "Pages in this section are regenerated on every build from the",
        "`sphinx-asr` submodule and its git history:",
        "",
        "- [Settings reference](settings.md): every key in the experiment and",
        "  corpus YAML files, with defaults and meanings.",
        "- [Settings changelog](changelog.md): commits that changed how settings",
        "  are defined or applied.",
        "- [Experiment registry](registry.md): experiments found on disk and their",
        "  results.",
        "",
        "See [Workload](../architecture/workload.md) for how sphinx-asr runs and",
        "the [API reference](../api/index.md) for the code.",
        "",
    ])


def main() -> None:
    """Write the experiment pages into the gen-files virtual tree."""
    import mkdocs_gen_files

    pages = {
        "index.md": index_page(),
        "settings.md": settings_page(SPHINX_DIR),
        "changelog.md": changelog_page(SPHINX_DIR),
        "registry.md": registry_page(collect_registry(experiments_dir())),
        "SUMMARY.md": "- [Overview](index.md)\n- [Settings reference](settings.md)\n"
        "- [Settings changelog](changelog.md)\n- [Experiment registry](registry.md)\n",
    }
    for name, text in pages.items():
        with mkdocs_gen_files.open(f"{OUT_DIR}/{name}", "w") as fh:
            fh.write(text)


if __name__ in {"__main__", "<run_path>"}:
    main()
