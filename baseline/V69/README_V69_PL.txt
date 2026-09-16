V69 = V68 + zaakceptowany WoWControlHub V1 + ABI-enabled SpeedFloor.

Zakres promocji jest celowo wąski:
- wszystkie moduły V68 pozostają bez zmian poza SpeedFloor,
- SpeedFloor używa zaakceptowanego runtime SHA256 a4dd0b0c44ecb4863231e0c92bab6767f3336003980fb552dc173448ab4b239c,
- dodany jest WoWControlHub.dll SHA256 f444a7c0c4769cc2f9546847fef54d41a0ccb79e823d132b73277e858571cf89,
- ControlHub otwiera się klawiszem Insert,
- ControlHub wykrywa SpeedFloor przez W112_CONTROL_API_V1 i steruje live: Enabled, Minimum Speed, Disable on hostile player,
- dlls.txt zawiera ControlHub jako dziewiąty aktywny DLL.

Nie promowano równoległych eksperymentów PickPocket/MovementCore z branch work.

Test w grze: użytkownik potwierdził poprawne wyświetlanie panelu oraz działanie zmian SpeedFloor live.
