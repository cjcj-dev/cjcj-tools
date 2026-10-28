package cjlint

import cjcj::ast.Node
import cjcj::basic.Position
import std.fs.File as SourceFile
import std.convert.Parsable
import std.regex.{Regex, RegexFlag}

func publicHardcodedIp(text: String): Bool {
    let parts = text.split(".")
    if (parts.size != 4) { return false }
    let octets = Array<Int64>(4, repeat: 0)
    for (index in 0..4) {
        if (let Some(number) <- Int64.tryParse(parts[index])) {
            if (number < 0 || number > 255) { return false }
            octets[index] = number
        } else { return false }
    }
    let a = octets[0]; let b = octets[1]; let c = octets[2]; let d = octets[3]
    if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)) { return false }
    if (a >= 224 && a <= 239) { return a == 224 && b == 0 && c == 0 && d == 0 }
    if (a == 127 || (a == 0 && b == 0 && c == 0 && d == 0)) { return false }
    if (a == 169 && b == 254 && c <= 254) { return c == 0 && d == 0 }
    return !(a == 255 && b == 255 && c == 255 && d == 255)
}

func checkHardcodedAddresses(engine: RuleEngine, root: Node): Unit {
    let _ = root
    let whitelist = settingStrings(ruleSettings(engine, "G_OTH_03"), "WhiteList")
    // This rule's original contract searches source text for literal addresses.
    // These expressions do not infer declarations, types or symbol identity.
    let expressions = [
        Regex(#"((?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?!\.|\d))"#),
        Regex(#"(((http|https|ftp|ftps)://)|(www\.))([一-龥\w\-]+[.])+(net|com|cn|org|cc|tv|edu|vip|top|hk|gov|biz)[一-龥\w\-\.,@?^=%&:/~\+#]*"#, [RegexFlag.Unicode]),
        Regex(#"([一-龥\w\-\.]+)@(((\w)+[.])+)(net|com|cn|org|cc|tv|edu|vip|top|hk|gov|biz)"#, [RegexFlag.Unicode])]
    let kinds = ["G_OTH_03_public_ip_hardcode_information", "G_OTH_03_public_url_hardcode_information",
        "G_OTH_03_public_email_hardcode_information"]
    let lines = String.fromUtf8(SourceFile.readFrom(engine.path)).split("\n")
    for (line in 0..lines.size) {
        for (index in 0..expressions.size) {
            for (found in expressions[index].findAll(lines[line])) {
                let text = found.matchString(0)
                if (whitelist.contains(text) || (index == 0 && !publicHardcodedIp(text))) { continue }
                let location = found.matchPosition(0)
                engine.findings.add(Finding(engine.path, Position(engine.fileID, line + 1, location.start + 1),
                    Position(engine.fileID, line + 1, location.end + 1), kinds[index], [text]))
            }
        }
    }
}
