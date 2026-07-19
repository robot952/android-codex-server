package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Test
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.SandboxChoice

class ApprovalModeTest {
    @Test
    fun modesMapToCodexApprovalAndSandboxPolicies() {
        assertEquals("untrusted", ApprovalMode.RequestApproval.approvalPolicy)
        assertEquals(SandboxChoice.WorkspaceWrite, ApprovalMode.RequestApproval.sandbox)

        assertEquals("on-request", ApprovalMode.AutoApprove.approvalPolicy)
        assertEquals(SandboxChoice.WorkspaceWrite, ApprovalMode.AutoApprove.sandbox)

        assertEquals("never", ApprovalMode.FullAccess.approvalPolicy)
        assertEquals(SandboxChoice.FullAccess, ApprovalMode.FullAccess.sandbox)
    }
}
