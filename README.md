# Meph - Movement Disabler Addon

Simple addon that automatically disables your movement keys when Mephistroth (or other configured bosses/characters) cast specific spells, like Shackles of the Legion.

## Installation

Put the "meph" folder into your WoW addons directory:

```
addons/meph/
├── meph.toc
├── meph.lua
```

## How it Works

- **Automatic**: Works immediately when addon is loaded
- **Default Target**: Mephistroth casting "Shackles of the Legion"
- **Smart Detection**: Waits for you to stop moving (default: 0.5sec), then disables movement keys (congigurable via /meph wait <insert number of seconds> - example: /meph wait 0.3/0.5/1.0)
- **Auto Restore**: Keys are restored when the debuff wears off
- **Emergency Restore**: Keys automatically restored after 12 seconds (configurable via /meph emergency <insert number of seconds> - example /meph emergency 12/15/20)

## Testing & Configuration

Type `/meph` in chat to see all available commands:

- `/meph test` - Test the movement disable system
- `/meph debug` - Toggle debug messages
- `/meph list` - Show configured targets (Mephistroth is already added by default)
- `/meph reset` - Reset if something goes wrong to default values

## Adding New Targets

```
/meph target "Boss Name" "Spell Name" "Debuff Name"
```

Example:
```
/meph target "Mephistroth" "Shackles of the Legion" "Shackles of the Legion"
/meph target PlayerMage Frostbolt Frostbolt
```

## Settings

- `/meph wait 0.5` - Grace period before disabling keys (0.1-3.0 seconds)
- `/meph emergency 12` - Emergency restore time (5-30 seconds)

All settings are automatically saved between sessions.

## Notes

- Works with movement keys bindings ("MOVEFORWARD", "MOVEBACKWARD", "STRAFELEFT", "STRAFERIGHT", "TURNLEFT", "TURNRIGHT", "JUMP", "TOGGLEAUTORUN")
- Compatible with Turtle WoW and vanilla clients based on Engine 1.12
- Safe emergency restore prevents permanent key lockouts
- Only removes keybindings if no input for long enough - previous addons removed Keybindings while keys were pressed, which caused the key input to be stuck (W continued forward walking)
