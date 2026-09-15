V67 - HARD 5.0s STEALTH W WoW.exe + V66 AutoPP blacklist/HARDLOS3D
World of Warcraft 1.12.1 build 5875 x86 - lokalne/prywatne srodowisko testowe

NOWY EXE
WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe

STEALTH CD - TWARDY PATCH W EXE
- Patch jest bezposrednio w WoW.exe, a nie tylko w DLL.
- Centralna funkcja wpisujaca cooldown: 0x006E12C0.
- Oryginalne bajty: 55 8B EC 8B 45 14.
- Entry args build 5875:
    [esp+0x10] recovery duration
    [esp+0x14] spellId
    [esp+0x1C] category recovery duration
- Dla spellId 1784, 1785, 1786, 1787:
    recovery = 5000 ms
    category recovery = min(category recovery, 5000 ms)
- Rozpoznanie wszystkich 4 rankow: (spellId & 0xFFFFFFFC) == 0x000006F8.
- Entry 0x006E12C0 skacze do code cave 0x0075D401, po czym wraca do 0x006E12C6.
- Guardian v2 zostaje aktywny jako druga warstwa. Poniewaz EXE ma teraz JMP w entry,
  Guardian powinien rozpoznac go jako foreign chain i chainowac dalej do 0x0075D401.

WAZNE
Ten patch twardo ogranicza KLIENTOWY wpis cooldownu Stealth do 5.0 s. Jezeli lokalny
serwer niezaleznie od klienta odrzuci cast przed uplywem 10 s (server-side cooldown),
EXE nie moze tego sam zmienic i wtedy trzeba poprawic cooldown po stronie core/DB serwera.

ZACHOWANE Z V66
- Empty pockets (0x72) = AutoPP blacklist GUID az do zgonu.
- PP HARDLOS3D retry.
- F11 AutoPP ON/OFF.
- Player target guard.
- Mining-first + Mining HARDLOS + Mining w combat.
- WoWPlayerESP v1.2.
- StealthCDGuardian v2 watchdog.

TEST STEALTH
1. Zamknij klienta.
2. Uruchom nowy EXE z V67.
3. Wejdz w Stealth rank 1-4 i wyjdz ze Stealth.
4. Cooldown klienta powinien byc maksymalnie 5.0 s.
5. Sprawdz WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.log.
   Przy tym EXE LOAD powinien pokazac chain_mode=1 / next=0x0075D401 po instalacji hooka.
6. Jezeli UI pokazuje 5 s, ale serwer przed 10 s odpowiada "ability is not ready yet",
   problem jest juz jednoznacznie server-side.

ROLLBACK
Oryginalny V66 EXE jest w rollback_v66_exe/.
