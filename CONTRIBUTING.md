# Contributing

Thanks for your interest in sbtfix! You can help in three main ways.

## 1. Report your headphones model

sbtfix has only been tested on the WH-1000XM5. If you have other Sony headphones, open a
[device report](../../issues/new?template=device-report.md) saying what works and what doesn't.
Debug logs help a lot:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "io.github.htsecurity.sbtfix"'
```

## 2. Decode more of the protocol

[docs/PROTOCOL.md](docs/PROTOCOL.md) lists messages that are seen but not yet understood. To
investigate:

1. Stream the debug log (above). Every frame is logged as `tx …` (sent) and `rx …` (received).
2. Change a setting on the headphones, or in the Sony phone app, and note which `rx` payloads
   show up.
3. Document what you find in `docs/PROTOCOL.md`.

## 3. Code

```sh
swift test      # protocol unit tests
./build.sh      # build the .app bundle
```

Guidelines:

- **`SonyProtocol` stays pure Swift.** No IOBluetooth and no UI in it, so everything in it can
  be unit-tested. When you add a command, add its builder and parser there, with a test that uses
  real bytes captured from a device.
- Per-model differences go in `DeviceProfile.swift`. Prefer learning a feature from the
  device's own replies, as the ambient layout and Speak-to-Chat already are, over hard-coding it.
- `HeadphoneController` owns the Bluetooth connection and the one-command-at-a-time queue.
  Settings that can change rapidly, like sliders, should pass a `key` to `enqueue` so repeated
  changes are merged and only the latest value is sent.
- Match the style of the code around your change, and keep pull requests focused.
- Describe how you tested, including the headphone model and firmware version.

## Ideas / roadmap

- Equalizer presets and custom bands
- DSEE Extreme, connection quality (LDAC / priority on stable connection)
- Automatic power off, pause when taken off
- Speak-to-Chat sensitivity and timeout
- Global keyboard shortcut to cycle modes
- App icon, notarized releases, Homebrew cask
