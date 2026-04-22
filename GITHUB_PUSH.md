# GitHub Push — Operation PIPELINE BREACH

## Initial Setup

```bash
git init APT41_Operation_PIPELINE_BREACH
cd APT41_Operation_PIPELINE_BREACH
cp -r /path/to/extracted/* .
git add .
git commit -m "APT41 Operation PIPELINE BREACH - Initial Release"
git remote add origin https://github.com/theflashsrk-1/APT41_Operation_PIPELINE_BREACH.git
git branch -M main
git push -u origin main
```

## Updating

```bash
cd APT41_Operation_PIPELINE_BREACH
git add .
git commit -m "Update: <description>"
git push origin main
```

## Cloning for Deployment

```bash
git clone https://github.com/theflashsrk-1/APT41_Operation_PIPELINE_BREACH.git
cd APT41_Operation_PIPELINE_BREACH
```

## File Structure

```text
APT41_Operation_PIPELINE_BREACH/
├── README.md
├── STORYLINE.md
├── NETWORK_DIAGRAM.md
├── AssessmentQuestions.md
├── GITHUB_PUSH.md
└── machines/
    ├── Exploit.sh
    ├── M1-DC/
    │   ├── setup.ps1
    │   └── setup-post.ps1
    ├── M2-LNXW/
    │   └── setup.sh
    ├── M3-LNXBUILDER/
    │   └── setup.sh
    ├── M4-LNXPROC/
    │   └── setup.sh
    └── M5-MGMT/
        └── setup.ps1
```

## Notes

- This package intentionally omits the `ttps/` directory because it is maintained separately.
- `machines/Exploit.sh` is the supplied red-team trigger chain for deterministic log generation.
- Build the machines first, then push once the structure and naming are final.
