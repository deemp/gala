package org.gala.ide.intellij

import com.intellij.codeInsight.completion.CompletionContributor
import com.intellij.codeInsight.completion.CompletionContributorEP
import com.intellij.codeInsight.completion.CompletionParameters
import com.intellij.codeInsight.completion.CompletionPhase
import com.intellij.codeInsight.completion.CompletionResultSet
import com.intellij.codeInsight.completion.impl.CompletionServiceImpl
import com.intellij.codeInsight.editorActions.TypedHandlerDelegate.Result
import com.intellij.codeInsight.lookup.LookupElementBuilder
import com.intellij.ide.plugins.PluginManagerCore
import com.intellij.testFramework.PlatformTestUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.testFramework.fixtures.CompletionAutoPopupTester
import com.intellij.testFramework.runInEdtAndGet
import com.intellij.testFramework.runInEdtAndWait

/**
 * Covers [GalaTypedHandler]: typing `.` in a GALA file opens member completion
 * directly, whatever phase an earlier completion left behind, and stays quiet
 * inside comments and string literals.
 *
 * The real completion items come from the language server, which is not running
 * here, so [MemberContributor] stands in for it.
 *
 * The tests run off the event dispatch thread with auto-popup enabled, so
 * [CompletionAutoPopupTester] can wait for the asynchronous popup to settle the
 * way it does in the IDE.
 */
class GalaTypedHandlerTest : BasePlatformTestCase() {

    private lateinit var tester: CompletionAutoPopupTester

    override fun runInDispatchThread(): Boolean = false

    override fun setUp() {
        super.setUp()
        tester = CompletionAutoPopupTester(myFixture)
        MemberContributor.offerItems = true
        val core = checkNotNull(PluginManagerCore.getPlugin(PluginManagerCore.CORE_ID))
        CompletionContributor.EP.point.registerExtension(
            CompletionContributorEP(GalaLanguage.id, MemberContributor::class.java.name, core),
            testRootDisposable,
        )
    }

    fun testDotInCodeOpensCompletion() {
        configure("fun main() {\n    val name = \"gala\"\n    name<caret>\n}\n")

        tester.runWithAutoPopupEnabled { typeDot() }

        assertLookupShown()
    }

    /**
     * An auto-popup that finds nothing parks the completion phase in
     * [CompletionPhase.EmptyAutoPopup]; a `.` typed from there must still open
     * completion.
     */
    fun testDotOpensCompletionAfterEmptyAutoPopup() {
        configure("fun main() {\n    val name = \"gala\"\n    <caret>\n}\n")

        tester.runWithAutoPopupEnabled {
            MemberContributor.offerItems = false
            tester.typeWithPauses("n")
            assertNull("the empty auto-popup must not show a lookup", tester.lookup)
            val parked = runInEdtAndGet { CompletionServiceImpl.completionPhase }
            assertInstanceOf(parked, CompletionPhase.EmptyAutoPopup::class.java)

            MemberContributor.offerItems = true
            typeDot()
        }

        assertLookupShown()
    }

    fun testDotTypedWhileLookupIsOpenReopensCompletion() {
        configure("fun main() {\n    val name = \"gala\"\n    name<caret>\n}\n")

        tester.runWithAutoPopupEnabled {
            typeDot()
            assertNotNull("first '.' should open completion", tester.lookup)
            tester.typeWithPauses("m")
            assertNotNull("lookup should stay open while the prefix matches", tester.lookup)
            typeDot()
        }

        assertTrue(runInEdtAndGet { myFixture.editor.document.text }.contains("name.m."))
        assertLookupShown()
    }

    fun testDotInLineCommentDoesNotOpenCompletion() {
        configure("fun main() {\n    // see name<caret>\n}\n")

        tester.runWithAutoPopupEnabled { typeDot() }

        assertNull("no completion inside a comment", tester.lookup)
    }

    fun testDotInStringLiteralDoesNotOpenCompletion() {
        configure("fun main() {\n    val s = \"name<caret>\"\n}\n")

        tester.runWithAutoPopupEnabled { typeDot() }

        assertNull("no completion inside a string literal", tester.lookup)
    }

    fun testCheckAutoPopupClaimsOnlyDot() {
        configure("fun main() {\n    name<caret>\n}\n")
        val handler = GalaTypedHandler()

        runInEdtAndWait {
            val (project, editor, file) = Triple(myFixture.project, myFixture.editor, myFixture.file)
            assertEquals(Result.STOP, handler.checkAutoPopup('.', project, editor, file))
            assertEquals(Result.CONTINUE, handler.checkAutoPopup('(', project, editor, file))
        }
    }

    fun testCheckAutoPopupIgnoresOtherLanguages() {
        myFixture.configureByText("notes.txt", "name<caret>")
        val handler = GalaTypedHandler()

        runInEdtAndWait {
            assertEquals(Result.CONTINUE, handler.checkAutoPopup('.', myFixture.project, myFixture.editor, myFixture.file))
        }
    }

    private fun configure(text: String) {
        myFixture.configureByText("main.gala", text)
        assertInstanceOf(myFixture.file, GalaFile::class.java)
    }

    /**
     * Types `.` and waits for any completion it opens. The handler starts
     * completion from an invokeLater, so the event queue is drained before
     * waiting on the completion phase.
     */
    private fun typeDot() {
        tester.typeWithPauses(".")
        runInEdtAndWait { PlatformTestUtil.dispatchAllInvocationEventsInIdeEventQueue() }
        tester.joinAutopopup()
        tester.joinCompletion()
    }

    private fun assertLookupShown() {
        val lookup = tester.lookup
        assertNotNull("typing '.' should open completion", lookup)
        val shown = runInEdtAndGet { lookup.items.map { it.lookupString } }
        assertContainsElements(shown, MemberContributor.ITEM)
    }

    /** Stands in for the language server: offers one member while [offerItems] is set. */
    class MemberContributor : CompletionContributor() {
        override fun fillCompletionVariants(parameters: CompletionParameters, result: CompletionResultSet) {
            // An empty prefix matcher, like the server's own items, so the item is
            // offered wherever completion runs — inside a string literal the default
            // prefix would be the literal's text and would filter it out.
            if (offerItems) result.withPrefixMatcher("").addElement(LookupElementBuilder.create(ITEM))
        }

        companion object {
            const val ITEM = "memberFromTest"

            @Volatile
            var offerItems = true
        }
    }
}
