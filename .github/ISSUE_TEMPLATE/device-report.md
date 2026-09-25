---
name: Device report
about: Tell us whether sbtfix works with your headphones
title: "Device report: <model>"
labels: device-report
---

**Model:** (e.g. WH-1000XM4)
**Firmware version:** (System Information → Bluetooth, or the Sony app)
**macOS version:**

| Feature | Works? |
|---------|--------|
| Connects | |
| Noise Cancelling / Ambient / Off | |
| Ambient level & Focus on Voice | |
| Speak-to-Chat | |
| Battery | |

**Debug log** (optional, but very helpful):
Run `/usr/bin/log stream --level debug --predicate 'subsystem == "io.github.htsecurity.sbtfix"'`, launch the app, try each feature, and paste the output here.

```
paste log here
```
