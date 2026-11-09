# Safety and limitations

Cleaner previews candidates and rechecks files before deletion. The engine rejects links and protects selected file types. Running-browser checks reduce risk but cannot eliminate races with applications starting during cleanup. Changes in browser storage formats can affect compatibility.

Passwords, cookies, bookmarks and session files are outside the history allowlist. This is not a guarantee that every browser feature is unaffected. Firefox history is not cleared because it shares storage with bookmarks. Cached offline site data is not a default target.

History deletion is local, permanent and not secure erasure. Explorer list handling depends on Windows shell behavior; inspect your pins after use. A safety copy of its list is saved locally.

Do not publish logs containing usernames, folder paths or browsing information. The public release is unsigned and has no independent security audit.
