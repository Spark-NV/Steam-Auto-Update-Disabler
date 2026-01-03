# Steam Update Manager

A simple tool to help you control automatic updates for your Steam games.

## What does this do?

This tool lets you stop automatic updates for specific Steam games, or allow updates again when you want them. Note that this will also prevent manually trying to trigger steam updates too.

### Why would you want this?

- Save bandwidth: Stop games from downloading updates when you're on a slow internet connection
- Control timing: Update games when YOU want to, not when Steam decides
- Fix problems: Sometimes updates break games - this lets you pause them
- Mod Compatibility: Most games that have mod support will have there mods break when updates release, this prevents this, hell this is the sole reason i wanted to make this...for a few years now i been doing this manually and now decided to make it into a script.

## How to use it

1. Download the `Disable_Steam_Updates.ps1` file
2. Right-click the file and select "Run with PowerShell"
3. Allow the script to run (you **MIGHT** need to change execution policy...google how to do this if needed)
4. Click games on the left side to stop updates from being applied
5. Click games on the right side to alloww updates again

## What happens when you stop updates?

- Steam wont be able to modify the manifest for the selected game, this is apparantly one of ther own requirements to apply updates, since this isnt able to happen all steam updates will fail to install.
- You can still play the games normally, unless the game developer themselves have some check within the game requiring a specific version for online ofcourse.

## Important Notes

- If you can't re-enable updates with this tool (due to errors), you can manually fix it by:
  1. Finding the game's manifest file (usually in `Steam\steamapps\appmanifest_*.acf`)
  2. Right-clicking it and unchecking "Read-only" in the properties

## System Requirements

- Windows 10 or 11
