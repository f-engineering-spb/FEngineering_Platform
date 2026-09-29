Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
strDir = fso.GetParentFolderName(WScript.ScriptFullName)
strPyw = "pythonw.exe"

If fso.FileExists(strDir & "\runtime\python\pythonw.exe") Then
    strPyw = strDir & "\runtime\python\pythonw.exe"
ElseIf fso.FileExists("C:\Python314\pythonw.exe") Then
    strPyw = "C:\Python314\pythonw.exe"
End If

WshShell.CurrentDirectory = strDir
WshShell.Run """" & strPyw & """ """ & strDir & "\app\backend\server.py"" --host 127.0.0.1 --port 8780", 0, False
WScript.Sleep 2500
WshShell.Run "http://127.0.0.1:8780/", 1, False
