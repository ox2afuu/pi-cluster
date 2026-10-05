"""Tests for the build-time generators (pure functions only)."""

from pathlib import Path

import gen_api
import gen_experiments
import gen_uml


def test_module_identifiers_match_griffe_search_paths(tmp_path):
    """Files map to identifiers resolvable under scripts/ and scripts/lib/.

    Given:
        - A fake ``scripts/`` with ``train.py``, ``lib/config.py`` and a
          ``corpus`` package (``__init__.py`` and ``librispeech.py``).
        - Baseline: ``scripts/lib`` is itself a search path, so its modules
          are top-level.
    When:
        ``discover_modules`` scans the tree.
    Then:
        - The identifiers are ``config``, ``corpus``, ``corpus.librispeech``
          and ``train``, in that order.
    """
    scripts = tmp_path / "scripts"
    (scripts / "lib").mkdir(parents=True)
    (scripts / "corpus").mkdir()
    for rel in ("train.py", "lib/config.py", "corpus/__init__.py", "corpus/librispeech.py"):
        (scripts / rel).write_text('"""Doc."""\n')

    modules = gen_api.discover_modules(scripts, tmp_path)

    assert [m.identifier for m in modules] == ["config", "corpus", "corpus.librispeech", "train"]


def test_empty_submodule_renders_init_instructions(tmp_path):
    """A missing scripts directory yields a page, not a crash.

    Given:
        - A path that does not exist.
        - Baseline: with modules present the index is a table.
    When:
        ``discover_modules`` and ``index_page`` run.
    Then:
        - No modules are found.
        - The page tells the reader to run ``git submodule update --init``.
    """
    modules = gen_api.discover_modules(tmp_path / "absent", tmp_path)

    page = gen_api.index_page(modules)

    assert modules == []
    assert "git submodule update --init" in page


def test_registry_lists_malformed_experiments_as_unreadable(tmp_path):
    """Good experiments are tabulated; malformed ones are listed, not fatal.

    Given:
        - ``001/experiment.yml`` valid, with ``results.yml`` (commit, wer, ser).
        - ``002/experiment.yml`` with invalid YAML.
        - ``003/experiment.yml`` missing the decode section.
        - Baseline: an empty directory renders the empty-state page.
    When:
        ``collect_registry`` scans the directory and ``registry_page`` renders it.
    Then:
        - One row is readable, for ``001``, with WER 12.5.
        - ``002`` and ``003`` are listed as unreadable.
        - The page has an "Unreadable" section.
    """
    ok = tmp_path / "001"
    ok.mkdir()
    (ok / "experiment.yml").write_text(
        "train:\n  corpora:\n    - name: librispeech\n      splits: [train-clean-100]\n"
        "decode:\n  corpus: {name: librispeech, split: dev-clean}\n"
        "sphinxtrain:\n  CFG_NPART: 4\n"
    )
    (ok / "results.yml").write_text("commit: abc1234\nwer: 12.5\nser: 40.0\n")
    bad = tmp_path / "002"
    bad.mkdir()
    (bad / "experiment.yml").write_text("train: [unclosed\n")
    nodecode = tmp_path / "003"
    nodecode.mkdir()
    (nodecode / "experiment.yml").write_text("train:\n  corpora:\n    - name: x\n      split: y\n")

    reg = gen_experiments.collect_registry(tmp_path)
    page = gen_experiments.registry_page(reg)

    assert [r.exp_id for r in reg.rows] == ["001"] and reg.rows[0].results["wer"] == 12.5
    assert sorted(i for i, _ in reg.unreadable) == ["002", "003"]
    assert "## Unreadable" in page


def test_yaml_comments_attach_to_keys():
    """Comments above a key and inline comments become that key's meaning.

    Given:
        - YAML with a banner, a comment above ``CFG_NPART``, an inline
          comment on ``lm`` and a commented-out ``DEC_CFG_WORDBEAM``.
        - Baseline: banner lines (``# ====``) are never meanings.
    When:
        ``extract_key_docs`` parses it.
    Then:
        - ``sphinxtrain.CFG_NPART`` has the comment above it.
        - ``lm`` has its inline comment.
        - ``sphinxtrain.DEC_CFG_WORDBEAM`` is an optional key with example ``"1e-40"``.
    """
    text = (
        "# ======\n# Section\n# ======\n\n"
        "lm: lm/x.arpa  # built by sphinx lm\n"
        "sphinxtrain:\n  # set to number of cores\n  CFG_NPART: 1\n"
        '  # DEC_CFG_WORDBEAM: "1e-40"\n'
    )

    doc = gen_experiments.extract_key_docs(text)

    assert doc.comments["sphinxtrain.CFG_NPART"] == "set to number of cores"
    assert doc.comments["lm"] == "built by sphinx lm"
    assert doc.commented_keys["sphinxtrain.DEC_CFG_WORDBEAM"] == '"1e-40"'


def test_uml_gallery_lists_every_diagram(tmp_path):
    """Every .puml in a package appears on the generated gallery page.

    Given:
        - ``docs/uml/01-pkg/`` with ``01a-x.puml`` (title line, svg) and
          ``01b-y.puml`` (no title, no svg).
        - Baseline: a package with a hand-written ``index.md`` is skipped.
    When:
        ``build_pages`` runs over ``docs/``.
    Then:
        - One page is produced, ``uml/01-pkg/index.md``.
        - It contains the escaped title of 01a and the ``01a-x.svg`` embed.
        - It falls back to the file name for 01b and flags the missing render.
    """
    pkg = tmp_path / "uml" / "01-pkg"
    pkg.mkdir(parents=True)
    (pkg / "01a-x.puml").write_text("@startuml\ntitle run_pigen <flow>\n@enduml\n")
    (pkg / "01a-x.svg").write_text("<svg/>")
    (pkg / "01b-y.puml").write_text("@startuml\n@enduml\n")

    pages = gen_uml.build_pages(tmp_path)

    assert list(pages) == ["uml/01-pkg/index.md"]
    page = pages["uml/01-pkg/index.md"]
    assert "run\\_pigen &lt;flow&gt;" in page and "(01a-x.svg)" in page
    assert "{#01b-y}" in page and "Missing render" in page
