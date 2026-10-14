// Disable LeakSanitizer at build time for the ASan-built fuzz target (SPEC §6.2 item 15).
extern "C" int __lsan_is_turned_off() { return 1; }
