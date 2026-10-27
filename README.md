# Infiniquarium wallpaper

**macOS only** (macOS 11 Big Sur or later).

A live planted aquarium as your desktop wallpaper. The tank is [Infiniquarium](https://bertholomus.com/trials/infiniquarium/): a closed system with its own nitrogen cycle, light and generations of animals, in one offline HTML file. This app runs that file behind your desktop icons and keeps it alive between sessions.

Claude Opus 5.5 wrote the tank and this app as part of the Infiniquarium trial on [bertholomus.com](https://bertholomus.com/trials/infiniquarium/). There, the same prompt was given to several models and every answer is published unedited.

## Requirements

- macOS 11 or later.
- Apple's command line tools (`xcode-select --install`). The installer builds the app from `Infiniquarium.swift` on your Mac, so there is no prebuilt binary to trust.

## Install

```bash
git clone https://github.com/bertholomus/infiniquarium-wallpaper.git
cd infiniquarium-wallpaper
bash install.sh
```

Or download the ZIP from GitHub and double-click `Install Infiniquarium.command`.

## Using it

A small menu-bar app that shows Infiniquarium behind your desktop icons. The wallpaper is only for looking at: clicks always go to your desktop.

- **Install or update:** double-click `Install Infiniquarium.command` (or run `bash install.sh`). It builds the app with Apple's compiler, puts it in `~/Applications/Infiniquarium.app` and starts it. Run it again after changing `infiniquarium.html`.
- **Feed, trim and explore:** click the fish in the menu bar and choose **Open in Browser**. That opens the wallpaper's own tank in your browser. While the tab is open it runs the tank and the wallpaper follows along; when you close or leave the tab, the wallpaper carries on from there.
- **The rest of the fish menu:** **Smoother Motion (60 fps)** (the default is 30 fps, which uses about half as much power), **Show On** to pick the display, and **Start at Login** (on by default).
- **Power:** while windows cover the whole desktop, the tank stops drawing (its clock keeps going) and uses next to no CPU.
- **Your tank** is saved in `~/Library/Application Support/Infiniquarium/tank.json`. It catches up on time the Mac was off or asleep.
- **Bringing in a tank from the plain HTML file:** in that browser tab, open About → Download a backup. Then use Open in Browser and About → Restore a backup there.
- **Privacy:** the browser link only works on this Mac (it's served to 127.0.0.1) and carries a private key, so other sites can't reach the tank.
- **Health check:** each install writes `wallpaper.log` and `wallpaper-snapshot.png` here, a short record of how the tank is running. You can delete them.
- **Remove it:** `bash uninstall.sh` (add `--all` to delete the saved tank too).

## License

MIT. See [LICENSE](LICENSE).
