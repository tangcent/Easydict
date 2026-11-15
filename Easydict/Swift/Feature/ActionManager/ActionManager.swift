//
//  ActionManager.swift
//  Easydict
//
//  Created by tisfeng on 2025/8/29.
//  Copyright © 2025 izual. All rights reserved.
//

import AppKit
import Defaults
import Foundation
import SelectedTextKit

// MARK: - ActionManager

/// Singleton class responsible for handling various application actions
@objc(EZActionManager)
class ActionManager: NSObject {
    // MARK: Internal

    // MARK: - Singleton

    @objc static let shared = ActionManager()

    var polishService = PolishingService()

    /// Global action choices reuse configured instances independently of window enablement.
    var translateAndReplaceServiceIDs: [String] {
        let identifiers = [ServiceType.builtInAI.rawValue] +
            [EZWindowType.main, .fixed, .mini].flatMap { LocalStorage.shared().allServiceTypes($0) }
        var seen = Set<String>()
        return identifiers.filter { identifier in
            guard seen.insert(identifier).inserted,
                  let service = QueryServiceFactory.shared.service(withTypeId: identifier),
                  !(service is AIToolService)
            else { return false }
            return service.supportedQueryType().contains(.translation)
        }
    }

    // MARK: - Text Field Detection and Access

    // MARK: - Public Methods

    /// Translate selected text and replace it with the translation result
    func translateAndReplace() async {
        logInfo("Translate and Replace")
        await executeTextReplacementAction(.translate)
    }

    /// Polish selected text and replace it with the polished result
    func polishAndReplace() async {
        logInfo("Polish and Replace")
        await executeTextReplacementAction(.polish)
    }

    // MARK: Private

    /// Type of text processing action
    private enum ProcessingType {
        case translate
        case polish
    }

    private let systemUtility = SystemUtility.shared

    // MARK: - Core Action Methods

    /// Common method to execute text replacement actions
    private func executeTextReplacementAction(_ type: ProcessingType) async {
        let enableSelectAll = Defaults[.autoSelectAllTextFieldText]
        let elementInfo = await systemUtility.focusedElementInfo(enableSelectAll: enableSelectAll)

        // Prepare translation request
        var queryText = elementInfo.focusedText
        if queryText?.isEmpty ?? true {
            queryText = await systemUtility.getSelectedText()
        }

        guard let queryText, !queryText.isEmpty else {
            logInfo("No text selected or focused for \(type), skipping action")
            return
        }

        // Prepare translation request
        guard let request = await prepareTranslationRequest(queryText: queryText, type: type) else {
            return
        }

        // Execute the selected service.
        await performTranslationService(request: request, elementInfo: elementInfo, type: type)
    }

    // MARK: - Helper Methods

    /// Prepare translation request from text field information
    /// - Parameters:
    ///   - queryText: Selected or focused text to translate or polish.
    ///   - type: The type of processing (translate or polish)
    /// - Returns: A configured TranslationRequest or nil if preparation fails
    private func prepareTranslationRequest(
        queryText: String,
        type: ProcessingType
    ) async
        -> TranslationRequest? {
        // Detect language and target
        let queryModel = try? await DetectManager().detectText(queryText)
        guard let detectedLanguage = queryModel?.detectedLanguage,
              let targetLanguage = queryModel?.queryTargetLanguage
        else {
            logError("Failed to detect target language, skipping \(type) and replace")
            return nil
        }

        // Create base request
        var request = TranslationRequest(
            text: queryText,
            sourceLanguage: detectedLanguage.code,
            targetLanguage: targetLanguage.code,
            serviceType: "",
            queryType: .translation
        )

        // Set service type based on processing type
        switch type {
        case .translate:
            let identifier = Defaults[.translateAndReplaceServiceID]
            guard translateAndReplaceServiceIDs.contains(identifier) else {
                await showTranslationReplacementFailure()
                return nil
            }
            request.serviceType = identifier
        case .polish:
            request.serviceType = polishService.serviceType().rawValue
        }

        return request
    }

    // MARK: - Streaming Service Methods

    /// Reuses the same insertion path for streaming and complete translation results.
    private func performTranslationService(
        request: TranslationRequest,
        elementInfo: FocusedElementInfo,
        type: ProcessingType
    ) async {
        guard let service = QueryServiceFactory.shared.service(withTypeId: request.serviceType)
        else {
            logError("Service type \(request.serviceType) not found")
            return
        }

        do {
            try Task.checkCancellation()
            let contentStream: AsyncThrowingStream<String, Error>
            if let streamService = service as? StreamService {
                logInfo("Using model: \(streamService.model)")
                contentStream = try await streamService.contentStreamTranslate(request: request)
            } else {
                let result = try await service.translate(request: request)
                if let error = result.error { throw error }
                guard let text = result.translatedText,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw QueryError(type: .noResult) }
                contentStream = AsyncThrowingStream { continuation in
                    continuation.yield(text)
                    continuation.finish()
                }
            }
            try Task.checkCancellation()
            try await replaceTextWithStream(contentStream, elementInfo: elementInfo)
        } catch {
            if Task.isCancelled {
                logInfo("Streaming task cancelled")
            } else {
                logError("stream failed: \(error.localizedDescription)")
                if type == .translate {
                    await showTranslationReplacementFailure()
                }
            }
        }
    }

    /// Replace text with streaming data
    @MainActor
    private func replaceTextWithStream(
        _ contentStream: AsyncThrowingStream<String, Error>,
        elementInfo: FocusedElementInfo
    ) async throws {
        logInfo("Replacing text with streaming content")

        // For avoding polluting user pasteboard content, we need to save and restore it when AX is not supported.
        let pasteboard = NSPasteboard.general
        var snapshotItems: [NSPasteboardItem]?

        let isSupportedAX = elementInfo.isSupportedAXElement
        if !isSupportedAX {
            snapshotItems = pasteboard.backupItems()
        }

        defer {
            if let snapshotItems, !isSupportedAX {
                pasteboard.restoreItems(snapshotItems)
            }
        }

        do {
            let textStrategy = systemUtility.textStrategies(for: elementInfo)

            /**
             - Note:
             For GitHub web text area, if select all and insert empty string,
             it will clear the text area and lose focus.
             So we do not insert empty string.
             */

            var reuslt = ""
            for try await content in contentStream where !content.isEmpty {
                //                logInfo("Received streaming content chunk: \(content.prettyJSONString)")

                reuslt += content
                await systemUtility.insertText(content, using: textStrategy)
            }
            guard !reuslt.isEmpty else { throw QueryError(type: .noResult) }
            logInfo("Final replacement result: \(reuslt.prettyJSONString)")
        } catch {
            logError("Streaming replacement failed: \(error)")
            throw error
        }
    }

    @MainActor
    private func showTranslationReplacementFailure() {
        EZToast.showText(NSLocalizedString("text_replacement.translation.failed", comment: ""))
    }
}
