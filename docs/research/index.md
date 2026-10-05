# Research

This wiki is the canonical **engineering** reference: how the cluster is
built, how sphinx-asr works, what the settings mean, what is broken. The
owner's thesis reasoning, literature notes and experiment interpretation
live in a separate Obsidian vault (the "2nd brain").

The two are connected in one direction only: the wiki pushes a small
summary note into the vault; the vault never writes back here.

## The vault export

After every commit, the post-commit hook runs
`tools/docs/export_vault_note.py`. It is **opt-in**:

- If `IVALICE_VAULT_DIR` is not set, it prints one line and does nothing.
- If it is set, it overwrites a single note,
  `$IVALICE_VAULT_DIR/${IVALICE_VAULT_SUBDIR:-Engineering}/ivaliceCluster Engineering Wiki.md`.

The note holds YAML frontmatter (type, source repository, branch, commit,
update time, tags) and a short body:

- the latest commit;
- how many review findings are still open (parsed from the Status column
  of the [review pages](../reviews/index.md));
- a summary of the [experiment registry](../experiments/registry.md);
- the last five entries of the [settings changelog](../experiments/changelog.md);
- `file://` links into the locally built site (`site/`), so a vault note
  can open the full page.

It never touches any other file in the vault, and the vault layout is
owned elsewhere: if the note should live in another folder, set
`IVALICE_VAULT_SUBDIR` rather than editing the script.

To enable it, export the variable in the shell that runs `git commit`
(for example in `~/.zshrc`):

```sh
export IVALICE_VAULT_DIR="$HOME/path/to/vault"
export IVALICE_VAULT_SUBDIR="Engineering"   # optional
```

Details of the hook chain are in
[Documentation workflow](../standards/documentation-workflow.md#vault-export).
