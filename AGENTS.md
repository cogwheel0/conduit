# Collaboration

- If a request is ambiguous, identify the consequential gap and ask a focused question before dependent work. Resolve routine design details from the approved interface and these rules.
- Be concise. Give findings and decisions without preambles, repeated summaries, or filler.

# UI design

Read `.impeccable.md` for the visual context when changing screens, controls, navigation, or prototypes. Apply the following interaction rules:

1. Start with the user's task and the whole flow. Explain a material usability conflict and recommend an alternative before building it; literal compliance alone is insufficient.
2. Inspect the equivalent existing control first. Reuse its appearance, icon meaning, placement, selection behavior, and dismissal behavior. Model selection follows the current compact model selector, including provider selection and Recommended/All supported models.
3. Show each piece of context once. Prefer concise names and current values. Include helper text only when it resolves a real ambiguity, consequence, or empty state. Remove repeated titles, file paths, status slogans, and workspace explanations from ordinary settings.
4. Group settings by what the user understands and changes, rather than mirroring backend files. Distinguish the bot's personality from what it remembers about the user; explain that distinction where the user edits the content.
5. Use one obvious entry point per action. Keep secondary detail behind an intentional tap. Preserve the established bottom-sheet, Cancel/Save, back, and swipe behavior.
6. Keep visible controls compact while retaining at least 48 × 48 dp Android touch targets, readable contrast, accessible names, and exposed selection states.
7. Use Hermes iconography consistently. Reuse the same icon for the same concept; use labels when an icon would be ambiguous.
8. When the existing app does not settle an interaction, consult current official Android/Material guidance or inspect the user's named reference. State the relevant tradeoff briefly; ask only when it changes the product decision.
9. Iterate on one coherent flow in the existing preview. Use sample state for prototypes; change production or install only when requested. Verify the rendered result and the affected interactions before reporting completion.
