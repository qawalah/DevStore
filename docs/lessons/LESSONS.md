# Lessons learned (shared by every DevStore app)

Rules that came out of real mistakes in the apps. Read this before building or changing an app's screens, flow or
device links. Each lesson says what to do, then what went wrong without it. Newest lessons go at the end of their
section, with the app and date they came from.

How lessons get here: see [README.md](README.md).

## Back, Exit and leaving

- **Back goes one screen back.** It closes the top thing first (menu, dialog, sheet, page), then goes one step back
  in a flow. It never jumps somewhere unrelated. *(AutoTune, 2026-11-14: Back from a connect page dropped the user at
  the first question and lost what they had typed.)*
- **Back never throws work away without asking.** If Back would lose something that took time (a measurement, a long
  form), ask first, and say what is lost. With nothing to lose, just go back. *(AutoTune: Back during the third of
  three microphone readings silently cancelled all three.)*
- **The top screen owns Back.** When a screen covers another, its Back handler must win. Check the order handlers
  are registered in. *(AutoTune: Back on a full-screen measuring view moved the hidden screen underneath.)*
- **One key leaves a flow.** In a guided flow, Back steps back and one Exit key leaves. Never make two keys that do
  the same thing.
- **Leaving is the same whichever way you leave.** If Exit asks a question, so must Back at the first step and so
  must switching tabs. Better: save as you go, so leaving never needs a question, and put Discard on the item's own
  menu.
- **After cancel, return to where the key was pressed**, not to the start of the flow.
- **Write the Back rule into the app's `CLAUDE.md`** as a small table (where, what Back does) and test it by
  pressing Back on every screen, during every long task, and with every menu and dialog open.

## What the app creates, it cleans up

- **Deleting a thing deletes what the app made for it.** If finishing a task quietly saved something (a preset, a
  profile, a rule, a setting on another device), deleting the task removes that too, and switches it off if it was in
  use. Only what the user saved by hand stays. Say in the delete question what goes. *(AutoTune: deleting a test left
  its EQ saved, switched on, and renamed "Your own bands".)*
- **Tie things together by id, never by name.** Names get renamed. *(AutoTune: renaming a test orphaned its saved
  EQ and made a duplicate.)*
- **Nothing is saved without the user seeing it happen.** If the app saves something for them, show it once where
  it happened ("saved as Car").
- **When moving from name links to id links, tie the old records once by name and write the id; never match by
  name again.** *(AutoTune, 2026-11-14: matching by name at every load would hand an old saved EQ to a new test
  that took a deleted test's name.)*
- **After a delete, nothing of the deleted thing stays on screen**: titles, graphs, "in use" labels, widgets,
  the other device.

## Names and words

- **One thing, one name, everywhere.** The same item must not be "Car" in one list, "Car · tuned (Run 1)" in another
  and "Your own bands" in a third.
- **Never name something by its date** or by a setting. When the user types no name, name it after what it is
  ("Car", then "Car 2").
- **One word per idea across the app.** Pick it (saved EQ, not profile / preset / saved EQ) and use it in every
  label, dialog and menu.
- **No jargon on the first screens.** A first-time user has not learned the app's words yet.
- **Say a thing once.** The same fact in the title, the status, the headline and the sentence is noise.

## Keys and signs

- **One sign, one meaning.** ">" opens a page. A down arrow unfolds in place. A key that acts at once has no
  arrow. Put this in the shared components so every screen follows.
- **No repeated keys.** The recommended action appears once. Do not list it and also pin it.
- **A key that needs permission does its job once permission is given.** Do not make the user press twice.
- **A disabled key looks disabled.**
- **"Suggested" only where there is a choice.** Under the only key on a screen it says nothing.
- **A destructive key offers Undo or asks.** *(AutoTune, 2026-11-14: "Flat" wiped the EQ in one press.)*
- **Remove what does nothing useful.** Before adding a key, ask what the user can do with it that they cannot do
  already. *(AutoTune: a "Try it: with EQ / without" section duplicated the EQ's own on/off switch.)*
- **Simple and Advanced: Advanced only adds.** A key shown in Simple must not move or vanish in Advanced.
- **No decks inside decks, no folds inside folds.**

## Flow

- **Count the presses to the first useful result** and cut them. Remember the last answers and offer "as last
  time" with a way to change.
- **Do not ask what you can work out.** Skip a question whose answer is already known.
- **Say what is about to happen before a long task** (how many steps, that the next one starts by itself), and
  start the next step by itself with a short countdown and a Pause.
- **Every dead end offers a way on.** "Nothing found" must come with what to check or another way to connect.
- **A screen with more than about five sections and nothing marked as the start is confusing.** Show only what is
  needed for the first step; reveal the rest when it becomes useful.
- **A finished task looks finished.** No "Continue" on something that is done, and it still looks done after the
  app restarts.
- **Lists show only what belongs to the current context.** Connected to one device, list that device's items
  only. *(AutoTune: on the PC the list offered the TV's results.)*

## Links between devices (phone, TV, PC)

- **Stop reaches the other side.** When the user stops on one device, the other stops playing or working.
- **When one side disappears, the other stops** and releases anything it was holding.
- **A dropped link says "connection lost"**, never a guess about something else (volume, permissions).
- **Both sides must notice a dead link**: a ping, an answer, and a silence timeout. A write that "succeeds" proves
  nothing.
- **A send that failed is reported.** Do not log or show "sent" when the link was closed.
- **Keep the screen on during long tasks** the user is not touching.
- **Short pairing codes need a limit on wrong tries** across all connections, not a pause per connection.
- **Announce again when the network changes**, and show the port when it is not the default.
- **Serialise reconnects** (one lock), or the page, the retry loop and the widget cut each other off.
- **Stay compatible both ways**: unknown messages are ignored, new abilities are announced, old ones keep working.

## How to audit an app (so these are caught before the owner finds them)

- **Run the real screens**, do not judge from code alone. If there is no device, build a harness that renders
  them and takes taps.
- **Walk every mode** (Simple and Advanced), **open every fold**, press every key.
- **Do the destructive things**: delete, rename, discard, cancel halfway, close and reopen the app. Then look at
  every other screen for leftovers.
- **Press Back everywhere**, especially during long tasks.
- **Walk it as someone who has never seen it**: what do they read first, what do they press, where do they stop?
- **For each key ask**: does the label say what it does, is it needed, is it where you would look?
- **Write findings in the repo** (an `AUDIT-<date>.md`) and mark each one done with its version.

## Working with Claude on an app

- **Compile and run all tests before pushing to `main`.** The push is the release.
- **Run one Gradle command at a time**; two at once corrupt the build cache.
- **Time a wait on screen by the UI's own clock** (its delays or frame time), not the wall clock, so it behaves
  the same in a test harness and on a device. *(AutoTune, 2026-11-14: "offer the address after 6 s" never fired in
  the harness.)*
- **Keep docs true**: when a flow, a key or a default changes, the app's `CLAUDE.md`, flow notes and store
  screenshots change in the same release.
- **Owner decisions are recorded with their date** in `CLAUDE.md`, so a later audit does not undo them.
