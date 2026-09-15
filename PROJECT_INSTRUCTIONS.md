# Project instructions — WoW 1.12

Projekt dotyczy wylacznie **World of Warcraft 1.12.1 build 5875 x86**.

## Zasady

- Nie mieszac API, struktur ani zalozen z TBC/Wrath/Retail.
- Zachowywac kompatybilnosc z buildem 5875.
- Preferowac male, punktowe zmiany zamiast przepisywania stabilnych modulow.
- Przed modyfikacja binarna zapisywac offset, oryginalne bajty, nowe bajty i sposob rollbacku.
- Przy zmianie DLL/EXE aktualizowac manifest SHA256 i `CURRENT_VERSION.md`.
- Nie usuwac dzialajacego rollbacku bez potrzeby.
- Nie zakladac, ze funkcja opisana w nazwie DLL faktycznie dziala — weryfikowac source, diff lub test.
- Aktywna lista runtime jest okreslona przez `dlls.txt`.

## Baseline

Pierwszym baseline repo jest V67 z katalogu `baseline/V67/`.
