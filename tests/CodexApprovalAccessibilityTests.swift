import Foundation

@main
struct CodexApprovalAccessibilityTests {
    static func main() {
        for labels in [
            ["Allow once", "Deny"],
            ["Allow once ⌘↵", "Deny Esc"],
            ["  Allow once\nEnter  ", "Deny\nEsc"],
            ["允许一次", "拒绝"],
            ["允許一次", "拒絕"],
            ["运行命令", "拒绝"],
            ["執行一次", "拒絕"]
        ] {
            precondition(CodexApprovalButtons.isApproval(labels))
        }
        for labels in [
            [],
            ["Allow once"],
            ["Deny"],
            ["Continue", "Cancel"],
            ["Submit", "Cancel"],
            ["Always allow", "Never allow"],
            ["How do I Allow once?", "Deny"],
            ["Approve request", "Decline request"],
            ["Allow once", "Deny access to websites"],
            ["允许一次", "取消"],
            ["已经允许一次", "拒绝"]
        ] {
            precondition(!CodexApprovalButtons.isApproval(labels))
        }
        precondition(!CodexApprovalButtons.isApproval(["Allow once"]))
        precondition(!CodexApprovalButtons.isApproval(["Deny"]),
                     "controls from different windows must be checked separately")
        print("Localized approval controls, shortcuts, and ordinary question/settings checks passed")
    }
}
