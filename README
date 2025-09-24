# LLM Zipper

LLM Zipper is a desktop utility written in **Perl + Gtk3** for organizing, previewing, and packaging project files into a single ZIP archive or copying their contents to the clipboard for use with large language models (LLMs).

It was designed to make it easier to assemble and share code/data snippets across multiple folders without leaving your editor.

---

## ✨ Features

- **Project roots**: Add one or more folders as “roots” for your workspace.
- **Tri-state project tree**: Include/exclude files and folders with checkboxes.
- **Favorites**: Star files/folders you use often; they are shown at the top of their container.
- **Preview pane**: Shows included files with size and timestamp; toggle individual files on/off temporarily without losing them from your set.
- **Clipboard integration**: Copy selected files (with their relative paths) as concatenated text for quick pasting into LLMs.
- **ZIP export**: Create timestamped ZIP archives of your selected files.
- **Profiles**: Save multiple profiles with different roots/selections.
- **Search**:
  - Filename filtering
  - Background content search (multithreaded) across all roots
  - Expansion state is preserved before/after a search
- **Progress spinner**: Shows while background search is active.
- **Persistent state**: Roots, selections, favorites, and preview toggles are saved per profile.

---

## 🚀 Installation

1. Make sure you have Perl 5.16+ with Gtk3 bindings installed:

   ```bash
   sudo apt install libgtk-3-dev
   cpanm Gtk3 Glib Path::Tiny Archive::Zip JSON::PP Encode

