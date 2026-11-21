# Installing Notadot

After changing the app, build it on the Mac and copy the signed bundle to the existing installation in `~/Applications`. Run these commands from the repository root.

```bash
bash scripts/build.sh &&
  ditto build/Notadot.app "$HOME/Applications/Notadot.app" &&
  codesign --verify --strict "$HOME/Applications/Notadot.app"
```
