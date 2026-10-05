# Docstring standards

Two styles, one rule each:

- **Application code** (everything that is not a test) uses
  [Google-style docstrings](https://google.github.io/styleguide/pyguide.html#38-comments-and-docstrings).
  mkdocstrings parses them with `docstring_style: google` to build the
  [API reference](../api/index.md), so sections that follow the format
  render as tables; anything else renders as plain text.
- **Tests** use GIVEN / WHEN / THEN docstrings, so each test reads as a
  specification of one behaviour.

## Application code: Google style

Rules:

1. A one-line summary in the imperative ("Return", "Load", "Build"),
   ending with a period, on the first line.
2. A blank line, then any extended description: what the function is
   for, not how it is implemented.
3. Sections in this order, each only when it applies: `Args`, `Returns`
   (or `Yields`), `Raises`, `Warning`, `Examples`.
4. `Args` lists every parameter by name with its meaning, unit and
   accepted values. Types live in the signature annotations, not in the
   docstring.
5. `Raises` names every exception the caller should expect and the
   condition that triggers it.
6. `Warning` holds anything that can silently produce a wrong result:
   for this project that usually means experiment validity.
7. `Examples` uses doctest syntax (`>>>`) so the example can be run.
8. Modules get a docstring that says what the module is for and how it
   is invoked (`Usage:`) when it is a CLI script.

Full example, using a helper in the style of `sphinx-asr/scripts/lib/config.py`:

```python
def resolve_split(corpus: dict, split_name: str, *, allow_missing: bool = False) -> dict:
    """Return the configuration of one split of a corpus.

    Looks up ``split_name`` under the ``splits:`` mapping of a loaded
    ``corpus.yml``. Used by ``sphinx setup`` for every training entry and
    for the decode corpus.

    Args:
        corpus: Parsed ``corpus.yml`` mapping, as returned by
            ``load_corpus``. Must contain a ``name`` key.
        split_name: Key under ``splits:``, for example ``"dev-clean"``.
        allow_missing: If true, return an empty mapping instead of raising
            when the split does not exist.

    Returns:
        The split's mapping (for example ``{"audio": "dev-clean/",
        "hours": 5.4}``), or ``{}`` when ``allow_missing`` is true and the
        split is absent.

    Raises:
        KeyError: If ``corpus`` has no ``name`` key.
        ValueError: If the split does not exist and ``allow_missing`` is
            false. The message lists the available splits.

    Warning:
        The same split name may be used for training and decoding. This
        function does not check for overlap; callers that build an
        experiment must, or the reported WER is measured on training data.

    Examples:
        >>> corpus = {"name": "librispeech", "splits": {"dev-clean": {"hours": 5.4}}}
        >>> resolve_split(corpus, "dev-clean")
        {'hours': 5.4}
        >>> resolve_split(corpus, "nope", allow_missing=True)
        {}
    """
    name = corpus["name"]
    splits = corpus.get("splits", {})
    if split_name in splits:
        return splits[split_name]
    if allow_missing:
        return {}
    available = ", ".join(splits)
    raise ValueError(f"Split '{split_name}' not found in corpus '{name}'. Available: {available}")
```

Classes document their public attributes in an `Attributes:` section in
the class docstring; dataclass fields count as attributes.

## Tests: GIVEN / WHEN / THEN

A test docstring is a small specification:

1. **Summary line**: the behaviour under test, in one sentence.
2. **`Given:`** every input *and* the expected baseline: the state the
   world is in before the action, stated so a reader can tell what
   "unchanged" would look like.
3. **`When:`** the single action under test. One action; if you need two,
   you need two tests.
4. **`Then:`** every assertion the test makes, one bullet per assertion,
   in the same order as the code.
5. **`Raises:`** when the action is expected to raise, each exception by
   name and the condition. Omit the section otherwise.

Full example (the style used in `tools/docs/tests/`):

```python
import pytest

from config import load_yaml  # sphinx-asr/scripts/lib/config.py


def test_load_yaml_rejects_a_list_document(tmp_path):
    """A YAML file whose top level is a list is rejected, not coerced.

    Given:
        - ``experiment.yml`` in a temporary directory containing ``- a\\n- b\\n``.
        - Baseline: ``load_yaml`` returns a ``dict`` for every valid
          mapping and ``{}`` for an empty file; nothing else is accepted.
    When:
        ``load_yaml`` is called on that file.
    Then:
        - The exception message names the offending path.
        - The file on disk is unchanged.
    Raises:
        TypeError: because the document is a list, not a mapping.
    """
    path = tmp_path / "experiment.yml"
    path.write_text("- a\n- b\n")

    with pytest.raises(TypeError) as excinfo:
        load_yaml(path)

    assert str(path) in str(excinfo.value)
    assert path.read_text() == "- a\n- b\n"
```

The test body mirrors the docstring: arrange (Given), one call (When),
then the assertions in the order `Then:` lists them.

## Where these rules come from

- Martin Fowler, [GivenWhenThen](https://martinfowler.com/bliki/GivenWhenThen.html):
  structure a specification as preconditions, the behaviour being
  specified, and the expected changes.
- Robert C. Martin, *Clean Code*, chapter 9 "Unit Tests": tests are
  read far more than written, so each test should be readable, check a
  single concept, and follow a build-operate-check shape.
- [Google Python Style Guide, section 3.8](https://google.github.io/styleguide/pyguide.html#38-comments-and-docstrings)
  for the application-code sections, which mkdocstrings understands
  natively.

## Status

The `sphinx-asr` docstrings are being converted to this style in the
`sphinx-asr` repository; until the submodule pointer is bumped, the API
reference shows a mix. Pages render either way.
