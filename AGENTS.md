# Baudrate — Agent Guidelines

This file supplements `CLAUDE.md` with Phoenix/Elixir coding conventions specific to this project.
When conflicts exist, `CLAUDE.md` takes precedence.

## Project-Specific Rules

- **Do NOT** wrap templates with `<Layouts.app>` — auto-layout via `live_session` handles this; wrapping causes duplicate flash IDs
- **Use DaisyUI** component classes (`btn`, `card`, `badge`, `modal`, etc.) — this is the project's UI library
- This project uses `@current_user` (NOT `current_scope`) for the authenticated user assign
- Tailwind CSS v3 configuration is used (NOT v4 import syntax)
- Use `Req` for all HTTP requests — never use `:httpoison`, `:tesla`, or `:httpc`
- Use `mix precommit` after all changes to run compile, format, and test checks

## Elixir Conventions

- Never nest multiple modules in the same file
- Never use `String.to_atom/1` on user input — use `String.to_existing_atom/1` only on trusted input
- Predicate functions end with `?` (e.g. `can_edit_article?/2`), reserve `is_` prefix for guards
- Use `Ecto.Changeset.get_field/2` to access changeset fields, not map access syntax
- Fields set programmatically (e.g. `user_id`) must not appear in `cast` calls
- Always `import Ecto.Query` when writing queries

## HEEx Templates

- Always use `~H` sigil or `.html.heex` files — never `~E`
- Use `{@assign}` for interpolation in tag attributes and bodies
- Use `<%= ... %>` only for block constructs (`if`, `for`, `case`, `cond`)
- Use the `<.icon name="hero-..." />` component for all icons
- Use the `<.input>` component from `core_components.ex` for form inputs
- Always wrap user-visible text in `gettext()` — never bare English strings
- HEEx comments: `<%!-- comment --%>`

## LiveView

- Never use deprecated `live_redirect`/`live_patch` — use `<.link navigate={...}>` / `<.link patch={...}>`
- Use `push_navigate`/`push_patch` in LiveView code
- Use `phx-trigger-action` pattern for session writes (POST to controllers)
- Use LiveView streams for collections to avoid memory issues
- Always provide unique DOM IDs on forms, buttons, and key elements
- Avoid LiveComponents unless there is a strong need

## Testing

- Use `start_supervised!/1` for process cleanup between tests
- Avoid `Process.sleep/1` — use `Process.monitor/1` + `assert_receive {:DOWN, ...}` or `:sys.get_state/1`
- Test against element IDs and structure, not raw HTML text
- Use `Phoenix.LiveViewTest` functions: `element/2`, `has_element?/2`, `render_submit/2`, `render_change/2`
