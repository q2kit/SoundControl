# SoundControl

A small menu bar app for macOS that gives every app its own volume slider and its own output device.
Keep your music on the speakers while a call goes to your headphones, turn one noisy app down without
touching the rest, or mute an app you never want to hear.

## Requirements
- macOS 14.4 or later (it relies on Core Audio process taps)
- Xcode 16 or later

## Download
Grab `SoundControl.zip` from the [latest release](https://github.com/q2kit/SoundControl/releases/latest),
unzip it and move **SoundControl.app** to Applications. Releases are built automatically whenever a pull
request is merged into `main`.

The builds aren't notarized, so the first time macOS will say it can't verify the app. Right-click it and
choose **Open**, or run `xattr -dr com.apple.quarantine /Applications/SoundControl.app` once.

## Building
Open `SoundControl.xcodeproj` and press **Run** (⌘R).

The first time you change an app's sound, macOS asks for permission to record system audio. That's how
SoundControl gets hold of each app's sound. If you said no by accident, turn it back on in
*System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only*.

The project signs with "Sign to Run Locally" by default. Pick your own team under
*Signing & Capabilities* and macOS will stop asking for the permission again after every build.

## What you can do
- Set a volume for each app, or mute it.
- Send each app to a different output device.
- Change the system output device and its volume right from the menu.
- When an app is sent to another device, that device shows up under the system output with its own
  volume slider, along with the icons of the apps using it.
- Hide apps you don't care about (**⋯** on the app's card → **Hide**). They move into a collapsed
  "Hidden" group at the bottom and keep their settings, so an app you always mute stays muted.
- In Settings (**⚙︎**): open at login, and choose which devices appear in the output pickers. Virtual
  devices created by other software are hidden out of the box.
- Everything is remembered per app and comes back when the app is opened again.
- Available in English and Vietnamese; it follows your macOS language.

## Translations
All text lives in String Catalogs: `SoundControl/Localizable.xcstrings` for the interface and
`SoundControl/InfoPlist.xcstrings` for the permission prompt. English is the source language. To add a
language, open the catalog in Xcode, add the language and fill in the strings.

## How it works
As long as an app is left alone (100%, not muted, following the system output), SoundControl doesn't
touch it at all.

Once you change something, SoundControl puts a *process tap* on that app: it takes the app's sound
before it reaches the speakers and silences the original. It then plays the sound itself, at the volume
you chose, on the device you chose. An app's helper processes (browsers have plenty) are grouped under
the app, so one slider covers all of them. Quit SoundControl and everything goes back to normal.

### The mute key and other devices
This one is worth knowing about. When you press the mute key (or turn the volume all the way down),
macOS mutes the system output, and for some devices it quietly mutes them too. A Bluetooth speaker,
for example, may simply follow your Mac's built-in speakers, while a pair of headphones doesn't. So if
an app is playing on that speaker, muting the system output would silence it as well, even though you
only meant the system output. Unmuting has the same problem: it turns the speaker back on even if you
had muted it yourself.

SoundControl undoes this. If a device that an app is using gets muted or unmuted at the same moment as
the system output, that's macOS copying the change, so SoundControl puts it back the way it was. The
gap is a few milliseconds, too short to hear. In the end, the volume keys only affect the system output.

How does it tell a copied change from one you made on purpose? Anything you do in SoundControl itself
is always respected, however fast you click, because the app knows it did it. For changes from outside,
such as the keyboard, Control Center or another app, the only clue is timing: two devices changing within
half a second of each other counts as copied. Muting that device yourself a little later is left alone.

### Limitations
The original app still plays to the system output behind the scenes. So when the system output device
changes (headphones connecting, for instance), the app has to reopen its audio stream, and you may hear
a short hiccup.

## License
MIT, see [LICENSE](LICENSE).
