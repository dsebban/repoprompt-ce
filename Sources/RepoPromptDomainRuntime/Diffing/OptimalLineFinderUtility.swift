import Dispatch
import Foundation

package class OptimalLineFinderUtility {
    package static func findOptimalLine(for change: FileChange, in content: [String], around startLine: Int, searchRadius: Int = 5) -> Int {
        // Check if the first context line has high similarity
        if let firstContextLine = change.diffChunk.lines.first(where: { $0.type == .context }) {
            if startLine < content.count,
               firstContextLine.content.similarity(to: content[startLine]) > 0.99
            {
                return startLine // Return original line if similarity is very high
            }
        }

        let lowerBound = max(0, startLine - searchRadius)
        let upperBound = min(content.count - 1, startLine + searchRadius)

        guard lowerBound <= upperBound else { return startLine } // Return original line if bounds are invalid

        let searchRange = lowerBound ... upperBound

        let queue = DispatchQueue(label: "com.repoprompt.linesearch", attributes: .concurrent)
        let group = DispatchGroup()

        let best = DomainLockedState(initialState: (score: -1, line: startLine))

        for line in searchRange {
            group.enter()
            queue.async(group: group) {
                let score = self.scoreMatch(diffChunk: change.diffChunk, in: content, startingAt: line)
                best.withLock { best in
                    if score > best.score {
                        best = (score, line)
                    }
                }
                group.leave()
            }
        }

        group.wait()
        let result = best.withLock { $0 }
        return result.score > -1 ? result.line : startLine // Return original line if no better match found
    }

    private static func scoreMatch(diffChunk: DiffChunk, in content: [String], startingAt line: Int) -> Int {
        var score = 0
        var contentIndex = line
        var maxScore = 0 // To normalize the score

        for diffLine in diffChunk.lines {
            guard contentIndex < content.count else { break }

            switch diffLine.type {
            case .context, .removal:
                let distance = diffLine.content.levenshteinDistance(to: content[contentIndex])
                let lineScore = max(diffLine.content.count, content[contentIndex].count) - distance
                score += lineScore
                maxScore += max(diffLine.content.count, content[contentIndex].count)

                // Increment contentIndex for both context and removal lines
                contentIndex += 1

            case .addition:
                // Skip additions entirely
                continue
            }
        }

        // Normalize the score to be between 0 and 100
        return maxScore > 0 ? Int((Double(score) / Double(maxScore)) * 100) : 0
    }

    package static func findOptimalLinesInParallel(for changes: [FileChange], in content: [String], searchRadius: Int = 5) -> [UUID: Int] {
        let queue = DispatchQueue(label: "com.repoprompt.optimallinefinder", attributes: .concurrent)
        let group = DispatchGroup()

        // One lock for the shared dictionary: per-change locks did not exclude concurrent writers.
        let optimalLines = DomainLockedState<[UUID: Int]>(initialState: [:])

        for change in changes {
            group.enter()
            queue.async(group: group) {
                let optimalLine = self.findOptimalLine(for: change, in: content, around: change.startLine, searchRadius: searchRadius)
                optimalLines.withLock { $0[change.id] = optimalLine }
                group.leave()
            }
        }

        group.wait()
        return optimalLines.withLock { $0 }
    }
}
