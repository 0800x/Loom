# Loom chat folders

Chat folders are a client-side organization feature. They do not create server-side conversation containers and they are not sent to a Home Node or federation peer.

## Behavior

The Chats pane shows the active folders above the conversation list. Users can switch folders in either of two equivalent ways:

- tap a folder name;
- swipe left or right across the conversation-list area.

The folder strip and the page position stay synchronized. Search is applied after the selected folder rule, so a search never leaks conversations from another folder into the current page.

The initial local folder set preserves the categories that previously existed as hard-coded UI filters:

- All;
- Unread;
- Personal;
- Groups;
- Pinned.

`All` is permanent and remains first. Other folders can be removed and reordered. `Muted` is also available as a recommended folder.

## Settings

Settings -> Chat Folders provides:

- recommended folders that are not currently active;
- drag reordering for active folders;
- removing non-permanent folders;
- custom folders;
- restoring the first-run defaults.

A custom folder has a local name and rules for chat type (personal/direct, group, Saved Messages) plus optional `Unread only`, `Pinned only`, and `Muted only` filters. Filters combine, so a folder can represent categories such as "Unread Personal" or "Pinned Groups" without inventing server-side labels.

Loom's current conversation model has `self`, `direct`, and `group` kinds. It does not expose Telegram-style `channel` or `bot` conversation kinds, so this feature does not create fake Channel/Bot categories that cannot match real Loom data.

## Persistence and privacy

Folder definitions are stored in the application's support directory as a small versioned JSON document scoped by the signed-in Loom identity ID. The file contains only folder configuration (name, ordering, and local filter flags); it does not contain message bodies, SDP/ICE data, credentials, or media.

On identity change, the controller loads that identity's local folder file. If the file is missing, the defaults are created. Invalid/oversized configuration is rejected and replaced with safe defaults rather than crashing the Chats pane.

Folder configuration is intentionally not synchronized through the Home Node in this client-side implementation.

## Tests

Focused client tests cover:

- rule matching against real `LoomConversation` metadata;
- per-identity persistence and folder ordering;
- Settings folder controls;
- tap-to-switch folder tabs;
- horizontal page swipe updating the selected folder.
