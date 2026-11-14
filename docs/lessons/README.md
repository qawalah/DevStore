# Lessons learned

One list of rules that came out of real mistakes in the apps, so the next app does not repeat them.

- [`LESSONS.md`](LESSONS.md): the shared list. **A Claude session reads this before building or changing an app's
  screens, flow or device links.**
- Each app repo keeps its own `LESSONS.md` (from `templates/app-repo/LESSONS.md`) for what it learns.

## The loop

1. **Read.** An app's `CLAUDE.md` tells Claude to read the shared list (fetch
   `https://raw.githubusercontent.com/qawalah/devstore/main/docs/lessons/LESSONS.md`, or the DevStore checkout
   when the session has one) before UI, flow or link work.
2. **Capture.** When a bug, an audit or the owner's feedback shows something a rule would have prevented, Claude
   adds it to the app's own `LESSONS.md` in the same change: the rule, then what went wrong, with the date.
3. **Feed back.** A lesson that would help other apps is marked `→ DevStore` in the app's `LESSONS.md`. Then:
   - if the session can reach `qawalah/devstore` (the `add_repo` tool with push access), Claude adds the lesson to
     `docs/lessons/LESSONS.md` here, under the right heading, with the app's name and date, pushes it, and changes
     the mark to `→ DevStore (sent <date>)`;
   - if it cannot, the mark stays. Any later session on DevStore collects the marked lessons from the app repos
     (step 4).
4. **Collect.** A session working on DevStore that is asked to "collect lessons" reads each app repo's
   `LESSONS.md`, copies the lessons still marked `→ DevStore` into the shared list, and marks them sent.

## Writing a lesson

- One or two lines: **what to do**, then *what went wrong without it*.
- General, not about one screen: "Back never throws work away without asking", not "fix Back on the measuring
  screen".
- No duplicates: if the shared list already has it, add the app's name to that lesson instead.
- App-only lessons (a quirk of one library or device) stay in the app's `LESSONS.md` and are not marked.
