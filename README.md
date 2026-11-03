# ClaimButton

A one-button plugin for [TriuneAutocombat](https://github.com/tunaria/TriuneAutocombat) (TAC) on
[Project Triune](https://nms.bestemu.com/). It shows at a glance whether your character holds the
NMS **active looter** slot, and claims it with one click.

> **Status: work in progress.** Showing who holds the slot works. Clicking the button while this
> character does not hold it (red) is still being validated; see [Known issues](#known-issues).

## What it does

| Colour | Meaning | Left click |
| --- | --- | --- |
| Green | This character is the active looter (`[NMS] Active looter: you.`) | Nothing |
| Red | Someone else holds the slot, or nobody does | Sends `#nms claim` |
| Grey | No answer from the server yet | Sends `#nms status` |

The button keeps itself up to date by sending `#nms status`:

- when it starts, and 5 seconds after each zone change;
- every 60 seconds by default (5–600 seconds, or off), counted from the last answer: if you or
  another plugin just asked, it does not ask again;
- about a second after a kill by you, your pets, your group or their pets. A burst of kills
  shares one query, at most one every 10 seconds;
- 1.5 seconds after a claim, to confirm it. The button stays dimmed until then.

While the button is closed it sends nothing on its own: no polling, no kill or zone queries. When
you show it again it asks once right away and polling resumes. **Ask now** and the
`/ac claimbutton` commands still work while it is closed.

Half a second after the mouse leaves it, the button fades to an idle opacity you choose. It turns
opaque again as soon as the mouse is back over it.

## Requirements

- A character on [Project Triune](https://nms.bestemu.com/). The `#nms` commands belong to that
  server's personal loot system.
- [MacroQuest](https://macroquest.org/) for the RoF2 emulator client, with its Lua plugin
  (MQ2Lua) loaded.
- [TriuneAutocombat](https://github.com/tunaria/TriuneAutocombat) 3.4 or later. ClaimButton is a
  TAC plugin and runs inside it. Tested with TAC 3.4.

## Installation

1. Download [`lua/tac/claim_button.lua`](lua/tac/claim_button.lua) from this repository
   (**Download raw file** on that page).
2. Copy it into the `lua\tac\` folder of your MacroQuest installation, next to TAC's own plugins
   (for example `C:\MacroQuest\lua\tac\claim_button.lua`).
3. In game, open TAC → **Settings** → **Plugins** and click **Rescan**. You can also restart TAC
   with `/lua stop triune` and `/lua run triune`.
4. **Claim Button** appears in the plugin list. Make sure **On** is ticked; the button shows up on
   screen.

TAC updates are extracted over the MacroQuest folder and leave `claim_button.lua` in place.

## Usage

### The button

- **Left click**: see the table above.
- **Hover**: a tooltip says who holds the slot and how old that answer is.
- **Move**: drag the button.
- **Resize**: drag the bottom-right corner, like any TAC window.

### Right-click menu

- **Idle opacity**: how visible the button stays when the mouse is away (10–100 %; 100 never
  fades).
- **Lock position & size**: the button can no longer be moved or resized.
- **UI scale** and **Window layout**: the same entries as every TAC window.
- **Close window**: hides the button.

### Showing the button again

After closing it, bring it back with any of the following; it then asks the server at once:

- the **Claim** button on the TAC main window header;
- TAC → **Settings** → **Plugins** → **Show** in the Claim Button row;
- `/ac claimbutton`.

### Settings

TAC → **Settings** → **Plugins** → **Config** in the Claim Button row holds every option. Settings
are saved per character.

| Option | Default | Range |
| --- | --- | --- |
| Poll `#nms status` | On | |
| Every (seconds) | 60 | 5–600 |
| Ask after a kill | On | |
| Idle opacity | 40 % | 10–100 % |
| Lock position & size | Off | |
| UI scale | Global | |

The panel also shows the current state and has an **Ask now** button.

### Commands

| Command | What it does |
| --- | --- |
| `/ac claimbutton` | Show or hide the button |
| `/ac claimbutton show` / `hide` | Show / hide the button |
| `/ac claimbutton status` | Ask the server now (`#nms status`) |
| `/ac claimbutton claim` | Claim the slot (`#nms claim`), same as clicking the red button |

## Notes

- Each query shows three lines in chat: the command itself (`You say, '#nms status'`) and the
  server's two replies (`[NMS] Active looter: …`, `[NMS] Offers waiting: …`). MacroQuest's Lua API
  can read chat lines but cannot hide them, and MacroQuest's `/filter` would hide them from the
  plugin too. If the lines bother you, poll less often, turn polling off, or close the button
  while you do not need it.
- Every character (box) has its own button, settings and queries.
- ClaimButton does not need TAC's **NMS Loot** plugin, and works alongside it: both read the same
  replies.

## Known issues

- **Claiming from another character on the same PC.** While another character running on the same
  computer holds the slot, `#nms claim` (typed in chat or sent by the red button) gets no reply,
  and `#nms status` keeps answering `Active looter: another character on this PC.` The Claim
  button in Triune's own loot window (`/nmsloot`) does move the slot. We are checking with the
  authors of Triune's client how a claim should be made in that case. Until then, use Triune's loot
  window when another character on your PC holds the slot.

## Uninstall

Delete `lua\tac\claim_button.lua` and click **Rescan**, or untick **On** to keep the file.

## Development

The tests run under plain LuaJIT 2.1, no MacroQuest needed:

```
luajit tests/test_claim_button.lua
```

## License

[MIT](LICENSE)
