# DockStacks

Stapel für das macOS-Dock. Fasse Apps zu Stapeln zusammen: Jeder Stapel bekommt ein eigenes Symbol im Dock und klappt beim Klick ein Raster auf, genau wie Downloads oder Dokumente.

## Download

**[DockStacks.zip herunterladen](https://github.com/aim0xyz/DockStacks/releases/latest/download/DockStacks.zip)**

Voraussetzungen: macOS 26 oder neuer, Mac mit Apple Silicon.

1. ZIP entpacken und `DockStacks.app` in den Ordner **Programme** ziehen.
2. DockStacks öffnen. Die App ist von Apple beglaubigt (notarisiert); macOS fragt beim ersten Start nur einmal nach, ob du die aus dem Internet geladene App öffnen willst.
3. In den Einstellungen den ersten Stapel anlegen und Apps hineinlegen.

## Funktionen

- Beliebig viele Stapel mit eigenem Namen, eigener Farbe und eigenem Dock-Symbol
- Raster im Launchpad-Stil, Apps per Drag & Drop sortieren
- Apps auf das Stapel-Symbol im Dock ziehen, um sie hinzuzufügen
- Apps eines Stapels optional aus dem Dock nehmen („Dock aufräumen“), mit Sicherung der vorherigen Dock-Belegung
- Punkt unter laufenden Apps, Start beim Anmelden

Optional fragt DockStacks nach der Freigabe für **Bedienungshilfen**. Damit zeigt der Pfeil des Rasters genau auf das Stapel-Symbol, auch wenn das Dock vergrößert. DockStacks liest dabei nur die Position der Dock-Symbole. Ohne Freigabe richtet sich das Raster nach dem Mauszeiger.

Deine Stapel und die Dock-Sicherungen liegen in `~/Library/Application Support/DockStacks`.

## Selbst bauen

Benötigt Xcode mit Swift 6.

```bash
./scripts/build.sh
```

Die fertige App liegt danach in `build/DockStacks.app`. Mit `--install` ersetzt das Skript zusätzlich `/Applications/DockStacks.app` und startet sie. Zum Signieren nimmt es das erste „Apple Development“-Zertifikat aus dem Schlüsselbund; eine andere Identität lässt sich mit `DOCKSTACKS_SIGN_IDENTITY` setzen (`-` für Ad-hoc).

`./scripts/release.sh` baut die beglaubigte `build/DockStacks.zip` für einen Release. Dafür braucht es ein „Developer ID Application“-Zertifikat und einmalig gespeicherte Zugangsdaten für Apples Notar-Dienst:

```bash
xcrun notarytool store-credentials notary --team-id <Team-ID>
```
