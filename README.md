# Meph - Advanced Movement Blocker

A TWOW 1.12 for Karazhan 40 Boss Mephistroth, that prevents movement during boss by safely blocking and unbinding movement keys. Designed specifically to prevent "stuck movement" scenarios where unbinding keys while they're held causes uncontrollable character movement.

## How It Works

The addon uses a **multi-layered safety system** to prevent stuck movement:

1. **Instant Input Blocking**: All keyboard input is immediately blocked when a configured spell is cast
2. **Movement Detection**: Monitors player position to detect when you've stopped moving
3. **Safe Unbinding Window**: Only unbinds keys after you've been stationary for 0.7 seconds
4. **Keyboard Release Period**: Maintains blocking for 0.5s after unbinding to ensure all keys are released
5. **Debuff Monitoring**: Continuously scans for the debuff and restores keys immediately after it expires
6. **Emergency Restore**: Automatic failsafe restores keys after 12 seconds

### Why This Approach?

Traditional key unbinding addons have a critical flaw: if you unbind a key while it's held down, the game never receives the key-up event, causing permanent movement in that direction. This addon solves this by:

- Blocking ALL input first (preventing new key presses)
- Waiting for you to release keys naturally (movement detection)
- Only unbinding once it's safe (stationary threshold)
- Preventing race conditions through proper cleanup

## Installation

Place the `meph` folder in your WoW addons directory:

```
Interface/AddOns/meph/
├── meph.toc
├── meph.lua
```

Reload UI or restart WoW.

## Key Features

### Smart Movement Detection
- Uses coordinate tracking to detect actual player movement
- 0.7 second stationary threshold ensures keys are safe to unbind
- Continuous monitoring during entire sequence
- No false positives from coordinate polling

### Comprehensive Debug System
- Scrollable debug window with full event logging
- Precise timestamps for timing analysis
- Detailed state tracking for troubleshooting
- All messages captured even when window closed

## Commands

### Basic Usage
- `/meph` - Show all commands
- `/meph list` - List configured targets
- `/meph debug` - Toggle debug window
- `/meph test` - Test blocking sequence
- `/meph testblock` - Test 3-second keyboard block
- `/meph reset` - Emergency reset (restores keys immediately)

### Configuration
- `/meph add "Caster" "Spell" "Debuff"` - Add new target
- `/meph remove <index>` - Remove target by number

### Examples
```
/meph add "Name" "Spell" "Debuff"
/meph add "Mephistroth" "Shackles of the Legion" "Shackles of the Legion"
```

## Default Configuration

**Target**: Mephistroth → "Shackles of the Legion" → "Shackles of the Legion"
**Emergency Timer**: 12 seconds
**Stationary Threshold**: 0.7 seconds
**Post-unbind Blocking**: 0.5 seconds

All settings saved between sessions in MephDB.

## What You'll See

### Normal Operation
```
MEPH: Mephistroth casting Shackles of the Legion! STOP MOVING NOW!!!
MEPH: Movement keys DISABLED!
[... debuff duration ...]
MEPH: Movement keys RESTORED! YOU CAN MOVE!
```

### Debug Mode
Enable with `/meph debug` to see:
- Exact timing of all events
- Key binding save/restore operations
- Movement detection state changes
- Debuff scan results
- Frame cleanup operations

## Technical Details

### Keys Affected
- `MOVEFORWARD` (typically W)
- `MOVEBACKWARD` (typically S)
- `STRAFELEFT` (typically A)
- `STRAFERIGHT` (typically D)
- `JUMP` (typically Space)

**Not affected**: 
- `TOGGLEAUTORUN` (kept bound so you can stop auto-run)
- `Left Mouse Button + Right Mouse Button` (Hardware bound, cant be disabled)

## Compatibility

- **Vanilla WoW 1.12.x**
- **Turtle WoW**
- **Any movement key bindings**
- **Does not use protected functions**

## Troubleshooting

**Keys never restore**: Use `/meph reset` for emergency restoration

**Addon not triggering**:
- Check `/meph list` to verify configuration
- Enable `/meph debug` to see cast detection
- Verify spell name matches exactly (case-sensitive)

## Development Notes

This addon was developed through extensive testing and debugging to eliminate all possible race conditions and stuck movement scenarios. Key improvements over traditional approaches:

- Blocking-first architecture (vs unbind-first)
- Movement detection (vs fixed timers)
- Race condition prevention (vs hope-and-pray)
- Comprehensive debug window logging (vs blind debugging)

All known edge cases have been addressed through actual testing with rapid consecutive casts, held keys during sequences, and intentional attempts to trigger stuck movement.