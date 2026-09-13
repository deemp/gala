package org.gala.ide.intellij

import com.intellij.codeInsight.completion.CodeCompletionHandlerBase
import com.intellij.codeInsight.completion.CompletionType
import com.intellij.codeInsight.editorActions.TypedHandlerDelegate
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.editor.ex.EditorEx
import com.intellij.openapi.project.Project
import com.intellij.psi.PsiFile
import org.gala.ide.intellij.psi.GalaTokenTypes

/**
 * Opens member completion when `.` is typed in a GALA file.
 *
 * Why the plugin owns this rather than leaving it to the platform's generic LSP
 * handler: that handler *schedules* an auto-popup through
 * AutoPopupController.scheduleAutoPopup, which silently returns unless the
 * completion phase is CompletionPhase.NoCompletion. Any earlier popup that has
 * not fully wound down — one that came back empty parks in EmptyAutoPopup, a
 * dismissed lookup can linger — leaves a different phase behind, and the next
 * `.` gets no popup, no request to the language server and no log line. That is
 * why member completion after a builder-chain call opened only some of the time,
 * while explicit invocation (Ctrl+Space) always worked.
 *
 * Explicit invocation works because it goes through
 * CodeCompletionHandlerBase.invokeCompletion instead, which starts by calling
 * the current phase's newCompletionStarted — for EmptyAutoPopup that resets the
 * phase to NoCompletion — and has no phase guard of its own. This handler takes
 * that same route for `.`, as an auto-popup (so an empty result stays quiet
 * rather than showing a "No suggestions" hint).
 */
class GalaTypedHandler : TypedHandlerDelegate() {

    /**
     * Claims the auto-popup decision for `.` in GALA files, so the platform's
     * scheduler does not also queue a popup that would race the one opened in
     * [charTyped].
     */
    override fun checkAutoPopup(charTyped: Char, project: Project, editor: Editor, file: PsiFile): Result =
        if (charTyped == '.' && file is GalaFile) Result.STOP else Result.CONTINUE

    override fun charTyped(c: Char, project: Project, editor: Editor, file: PsiFile): Result {
        if (c != '.' || file !is GalaFile || isInsideCommentOrString(editor)) return Result.CONTINUE

        // The character has been inserted but the typing action is still on the
        // stack; completion must start after it, on the event dispatch thread.
        ApplicationManager.getApplication().invokeLater({
            if (project.isDisposed || editor.isDisposed) return@invokeLater
            CodeCompletionHandlerBase
                .createHandler(CompletionType.BASIC, /* invokedExplicitly = */ false, /* autopopup = */ true, /* synchronous = */ false)
                .invokeCompletion(project, editor)
        }, ModalityState.stateForComponent(editor.contentComponent))
        return Result.CONTINUE
    }

    /**
     * Whether the `.` just typed sits inside a comment or string literal, where
     * a member popup would be noise.
     *
     * Read from the editor highlighter rather than PSI: the document has not been
     * committed at this point, so PSI still describes the text before the
     * keystroke, while the highlighter's lexer state is updated synchronously.
     */
    private fun isInsideCommentOrString(editor: Editor): Boolean {
        val offset = editor.caretModel.offset - 1
        if (offset < 0 || editor !is EditorEx) return false
        val tokenType = editor.highlighter.createIterator(offset).tokenType
        return GalaTokenTypes.COMMENTS.contains(tokenType) || GalaTokenTypes.STRINGS.contains(tokenType)
    }
}
