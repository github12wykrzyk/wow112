using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal static partial class AhEvidenceV2Feature
    {
        private static readonly JavaScriptSerializer EvidenceJson = new JavaScriptSerializer();

        private static void HandleClick(IUpdaterHost host, Button button)
        {
            button.Enabled = false;
            try
            {
                var rawRoot = (host.GameDirectory ?? "").Trim();
                if (!Directory.Exists(rawRoot)) throw new InvalidOperationException("Wybierz istniejący katalog gry.");
                var root = Path.GetFullPath(rawRoot);
                var baselinePath = BasePath(root);
                var head = InstalledHead(root);
                Baseline baseline = null;
                if (File.Exists(baselinePath))
                {
                    try { baseline = EvidenceJson.Deserialize<Baseline>(File.ReadAllText(baselinePath, Encoding.UTF8)); }
                    catch { baseline = null; }
                }
                if (baseline != null && !string.Equals(baseline.head_sha ?? "", head ?? "", StringComparison.OrdinalIgnoreCase))
                {
                    File.Delete(baselinePath);
                    baseline = null;
                    host.LogMessage("AH EVIDENCE V2: baseline odrzucony po zmianie installed HEAD.");
                }

                if (baseline == null)
                {
                    var sources = All(root).Where(x => x.Valid).OrderBy(x => x.Id).ToList();
                    if (sources.Count == 0)
                        throw new InvalidOperationException("Brak AuxVmangos.lua z shadowParity/shadowParityEvidence. MARKET nie jest wymagany.");
                    baseline = new Baseline {
                        head_sha = head ?? "", captured_utc = DateTime.UtcNow.ToString("o"),
                        sources = sources.Select(x => new BaseSource {
                            path=x.Path, id=x.Id, key=x.Key, write_ticks=x.WriteTicks,
                            scans=x.Scans, pages=x.Pages, records=x.Records, decisions=x.Decisions
                        }).ToList()
                    };
                    Directory.CreateDirectory(Path.GetDirectoryName(baselinePath));
                    File.WriteAllText(baselinePath, EvidenceJson.Serialize(baseline), new UTF8Encoding(false));
                    host.LogMessage("AH EVIDENCE V2 BASELINE: sources=" + sources.Count);
                    MessageBox.Show(host.Window,
                        "Baseline V2 zapisany dla " + sources.Count + " źródeł parity.\n\n" +
                        "Puść 2 pełne LOOP, zrób /reload i kliknij ponownie.\n" +
                        "V2 sam wykryje aktywny AuxVmangos.lua; MARKET nie jest wymagany.",
                        "AH Evidence Gate V2", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (baseline.sources == null || baseline.sources.Count == 0)
                    throw new InvalidOperationException("Uszkodzony baseline V2.");

                var pairs = baseline.sources.Select(source => {
                    var current = Read(root, source.path);
                    return new Pair { Before=source, After=current, Changed=Changed(source, current) };
                }).ToList();
                var moved = pairs.Where(x => x.Changed).ToList();
                var active = moved.Count == 1 ? moved[0] : null;
                var reasons = new List<string>();
                if (moved.Count == 0) reasons.Add("no-source-changed-after-baseline");
                if (moved.Count > 1) reasons.Add("ambiguous-active-sources=" + string.Join("+", moved.Select(x => x.Before.id).ToArray()));

                if (active != null)
                {
                    var after = active.After; var before = active.Before;
                    if (after == null || !after.Valid) reasons.Add("source-invalid:" + (after == null ? "missing" : after.Reason));
                    else
                    {
                        if (!string.Equals(after.Id, before.id, StringComparison.OrdinalIgnoreCase)) reasons.Add("source-id-changed");
                        if (!string.Equals(after.Key ?? "", before.key ?? "", StringComparison.Ordinal)) reasons.Add("compatibility-key-changed");
                        if (after.Scans < before.scans + 2) reasons.Add("scans-delta<2");
                        if (after.Pages <= before.pages) reasons.Add("pages-not-growing");
                        if (after.Records <= before.records) reasons.Add("records-not-growing");
                        if (after.Decisions <= before.decisions) reasons.Add("decisionCompared-not-growing");
                        if (after.Errors != 0) reasons.Add("observer-errors=" + after.Errors);
                        if (after.Mismatches != 0) reasons.Add("mismatches=" + after.Mismatches);
                    }
                }

                var verdict = reasons.Count == 0 ? "PASS" : "FAIL";
                var report = BuildReport(head, baseline, moved, active, verdict, reasons);
                var resultPath = Path.Combine(root, ".wow112_parallel_updater", ResultName);
                Directory.CreateDirectory(Path.GetDirectoryName(resultPath));
                File.WriteAllText(resultPath, report + (verdict == "FAIL" ? "\r\nbaseline_retained=true\r\n" : ""), new UTF8Encoding(false));
                if (verdict == "PASS") File.Delete(baselinePath);
                host.LogMessage("AH EVIDENCE V2 " + verdict + (reasons.Count == 0 ? "" : ": " + string.Join(",", reasons.ToArray())));
                MessageBox.Show(host.Window,
                    report + (verdict == "FAIL" ? "\r\nBaseline zachowany — następne kliknięcie nadal będzie CHECK." : ""),
                    "AH Evidence Gate V2 — " + verdict, MessageBoxButtons.OK,
                    verdict == "PASS" ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            }
            catch (Exception ex)
            {
                host.LogMessage("AH EVIDENCE V2 błąd: " + ex.Message);
                MessageBox.Show(host.Window, ex.Message, "AH Evidence Gate V2", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally { button.Enabled = true; Refresh(host, button); }
        }

        private static string BuildReport(string head, Baseline baseline, List<Pair> moved, Pair active, string verdict, List<string> reasons)
        {
            var text = new StringBuilder();
            text.AppendLine("AH EVIDENCE GATE V2: " + verdict);
            text.AppendLine("head_sha=" + (head ?? ""));
            text.AppendLine("baseline_utc=" + (baseline.captured_utc ?? ""));
            text.AppendLine("baseline_sources=" + baseline.sources.Count);
            text.AppendLine("changed_sources=" + (moved.Count == 0 ? "none" : string.Join(",", moved.Select(x => x.Before.id).ToArray())));
            text.AppendLine("active_source=" + (active == null ? "none" : active.Before.id));
            if (active != null && active.After != null)
            {
                var before=active.Before; var after=active.After;
                text.AppendLine("compatibility_key_before=" + (before.key ?? ""));
                text.AppendLine("compatibility_key_after=" + (after.Key ?? ""));
                text.AppendLine("write_ticks=" + before.write_ticks + " -> " + after.WriteTicks);
                text.AppendLine("scans=" + before.scans + " -> " + after.Scans + " (delta " + (after.Scans-before.scans) + ")");
                text.AppendLine("pages=" + before.pages + " -> " + after.Pages + " (delta " + (after.Pages-before.pages) + ")");
                text.AppendLine("records=" + before.records + " -> " + after.Records + " (delta " + (after.Records-before.records) + ")");
                text.AppendLine("decisionCompared=" + before.decisions + " -> " + after.Decisions + " (delta " + (after.Decisions-before.decisions) + ")");
                text.AppendLine("observerErrors=" + after.Errors);
                text.AppendLine("mismatches=" + after.Mismatches);
                text.AppendLine("source_valid=" + after.Valid);
            }
            if (reasons.Count > 0) text.AppendLine("reasons=" + string.Join(",", reasons.ToArray()));
            return text.ToString();
        }
    }
}
