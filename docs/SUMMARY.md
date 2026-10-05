<!-- Navigation for mkdocs-literate-nav. Entries that link to a directory
     (ending in "/") take their children from the SUMMARY.md that the
     generators in tools/docs/ write into that directory at build time. -->

- [Home](index.md)
- [Architecture](architecture/index.md)
    - [Build pipeline](architecture/build-pipeline.md)
    - [Provisioning](architecture/provisioning.md)
    - [Workload](architecture/workload.md)
- [Infrastructure](infra/index.md)
    - [GitLab CI](infra/gitlab-ci.md)
    - [Lab image](infra/lab-image.md)
- [Baselines](baselines/index.md)
    - [CentOS 6.10 legacy VM](baselines/rhel6-centos6.md)
- UML diagrams
    - [Phase 0 design](uml/)
    - [Code-verified set](uml-verified/)
- [Experiments](experiments/)
- [API reference](api/)
- Standards
    - [Docstrings](standards/docstrings.md)
    - [Documentation workflow](standards/documentation-workflow.md)
    - Decision records
        - [Overview](standards/adr/index.md)
        - [0001 MkDocs Material, mkdocstrings, PlantUML](standards/adr/0001-mkdocs-material-mkdocstrings-plantuml.md)
        - [0002 Dedicated Lima runner for image builds](standards/adr/0002-dedicated-lima-runner-for-image-builds.md)
        - [Template](standards/adr/template.md)
- [Reviews](reviews/index.md)
    - [2026-10-04 baseline](reviews/2026-10-04-baseline.md)
- [Research](research/index.md)
