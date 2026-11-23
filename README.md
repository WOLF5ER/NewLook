# Shelfside

<img src="Shelfside-icon.png" width="112" height="112" alt="Иконка Shelfside">

Shelfside — переносная панель ярлыков и виджетов для Windows 10 и 11. Скачайте [приложение из последнего выпуска](https://github.com/WOLF5ER/NewLook/releases/latest/download/NewLook.exe) и запустите файл. Имя загрузки `NewLook.exe` сохраняет совместимость с предыдущими выпусками.

Наведите указатель на ручку слева или щёлкните по ней. В панели можно создать папки, перенести ярлыки с рабочего стола и вернуть их обратно. Кнопка на ручке открывает календарь и заметку.

Папки, заметка и перемещённые файлы хранятся в `%LOCALAPPDATA%\NewLook`. Shelfside проверяет новые стабильные выпуски при запуске и периодически в фоне. Когда доступна новая версия, внизу списка папок появится кнопка **«Обновить»**. Обновление начинается после вашего щелчка и сохраняет данные приложения.

## Сборка и выпуск

Соберите приложение в Windows PowerShell 5.1 из корня репозитория.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-NewLook.ps1
```

Чтобы снова экспортировать ICO и PNG из оригинала `Shelfside.icon.xaml`, запустите `Build-ShelfsideIcon.ps1` в Windows PowerShell.

Для выпуска обновите `VERSION`, отправьте коммит в `main` и запустите следующую команду после входа в GitHub CLI. Скрипт соберёт переносный EXE, проверит его на временных данных и приложит к выпуску.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Publish-NewLook.ps1
```
