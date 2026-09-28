# Style references

`arcade_reference.png` is the default `--style-image` for `tools/whole_character_workflow.py`.
It is a single full character generated on 2026-09-25 with OpenAI's image model (ChatGPT) and is
the approved target look: 1990s arcade fighter sprite art with a slight, fine pixel texture.

`arcade_reference_atlas.png` is the earlier approved look (2026-09-22), as a twelve-part atlas with
its white gutters painted out. Pass it with `--style-image` to compare.

The character prompt tells the model to copy only a reference's rendering style, never what it depicts.
Use a reference without a frame or border: models copy those too.
