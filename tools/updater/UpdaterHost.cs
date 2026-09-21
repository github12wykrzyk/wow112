using System;
using System.Windows.Forms;

namespace WoW112Updater
{
    // Compile-time contract between MainForm and optional updater features.
    // Features must not discover MainForm private fields/methods via reflection.
    internal interface IUpdaterHost
    {
        Form Window { get; }
        string GameDirectory { get; }
        string GitHubToken { get; }
        bool IsStableChannel { get; }
        string SessionLogText { get; }
        string[] DisabledDllNames { get; }
        event EventHandler GameDirectoryChanged;
        void RegisterUiControl(string key, Control control);
        void SetBusy(bool value, string text);
        void SetStatus(string text);
        void LogMessage(string message);
        void RefreshLocalState();
    }

    internal sealed partial class MainForm : IUpdaterHost
    {
        void IUpdaterHost.RegisterUiControl(string key, Control control)
        {
            featureControls.Add(key, control);
        }

        Form IUpdaterHost.Window
        {
            get { return this; }
        }

        string IUpdaterHost.GameDirectory
        {
            get { return gameDir.Text.Trim(); }
        }

        string IUpdaterHost.GitHubToken
        {
            get { return token.Text.Trim(); }
        }

        bool IUpdaterHost.IsStableChannel
        {
            get { return IsStable(); }
        }

        string[] IUpdaterHost.DisabledDllNames
        {
            get { return GetDllInstallDisabledForSave(); }
        }

        string IUpdaterHost.SessionLogText
        {
            get { return log.Text ?? string.Empty; }
        }

        event EventHandler IUpdaterHost.GameDirectoryChanged
        {
            add { gameDir.TextChanged += value; }
            remove { gameDir.TextChanged -= value; }
        }

        void IUpdaterHost.SetBusy(bool value, string text)
        {
            SetBusy(value, text);
        }

        void IUpdaterHost.SetStatus(string text)
        {
            status.Text = text ?? string.Empty;
        }

        void IUpdaterHost.LogMessage(string message)
        {
            Log(message);
        }

        void IUpdaterHost.RefreshLocalState()
        {
            RefreshLocalState();
        }
    }
}

