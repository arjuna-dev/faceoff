# Character prompts

Reusable character identity and art-direction prompts live here, named by fighter
ID. The filename identifies the character for our code; the prompt itself does
not need to tell the image model the character's name.

`armk.txt` is the current angel prompt. Edit this file for future generations;
older prompts under `builds/` remain historical run evidence.

The workflow supplies the shared twelve-part layout, marker protocol, no-clipping
instructions and cleanup stage separately. Do not add instructions to generate or
remove markers to character identity files.

Example from the project root:

```sh
python3 tools/character_generation_workflow.py \
  --template builds/templates/geometric_dummy_v1.png \
  --character-prompt-file prompts/characters/armk.txt \
  --output-dir builds/generated/armk_next \
  --import-directory builds/fighters/armk_next --fighter-id armk
```

Add `--skip-artwork-drift-check` only when explicitly requested. Other validation
and visual review requirements remain enabled.
