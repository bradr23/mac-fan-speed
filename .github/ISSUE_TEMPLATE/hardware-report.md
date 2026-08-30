---
name: Problem on a particular Mac
about: Temperatures missing or wrong, sensors unnamed, or fan control not working
title: "[Mac model] short description"
labels: hardware
---

<!--
This app is tested on one machine and supports the rest by detecting fan
count, sensor names and the firmware unlock at runtime. Most gaps are a Mac
whose sensor names nobody has catalogued yet, and the two commands below are
usually enough to close one.
-->

**Mac model and chip** (Apple menu → About This Mac):

**macOS version:**

**What happens, and what you expected instead:**

---

### Diagnostics

Every sensor the app can see, and how it classified each one:

```
paste the output of:  ./build/fanctl temps --dump
```

<!--
Only if fan control is the problem. This works out what your firmware will
accept and always restores your original settings afterwards.
-->

```
paste the output of:  sudo ./build/fanctl probe-mode
```

<!--
If you installed the app from a release rather than building it, fanctl is
inside the bundle:
  /Applications/MacFanSpeed.app/Contents/Resources/fanctl temps --dump
-->

### Helper log

If fan control is involved, the last few lines of `/var/log/MacFanSpeedHelper.log`:

```

```
