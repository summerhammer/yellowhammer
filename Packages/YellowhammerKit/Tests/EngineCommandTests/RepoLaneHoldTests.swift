import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// spec ruling OQ182 (2026-10-22), items 2 and 5: `RepoLane.sequencePredecessors(of:)` and
// `RepoLane.holder(of:currentCard:)`, the shared same-repository hold predicate. Every newly authored
// Card of a lane belongs to one sequence; an adopted Card belongs to the sequence of the Cards adopted
// from the same previous Feature, and these two kinds of sequence never hold one another.

private let repoLaneHoldEpoch = Date(timeIntervalSince1970: 1_800_000_000)

/// A minimal fixture `CardRecord`, every column defaulted so a test only names what it's checking.
private func fixtureCard(
    id: Int64, authoredOrder: Int, state: CardState = .todo, removedFromBoard: CardRemoval? = nil,
    repository: String = "backend", title: String? = nil
) -> CardRecord {
    CardRecord(
        id: id, cycleID: 1, issueID: "CARD-\(id)", title: title, repository: repository, kind: "card",
        authoredOrder: authoredOrder, state: state, waitingReason: nil, blockReason: nil, shelvedFromState: nil,
        budgetEpoch: 0, createdAt: repoLaneHoldEpoch, stateVersion: 0, boardStateVersion: nil, unansweredNights: 0,
        unansweredLastCountedNightID: nil, failedAdoptions: 0, divergenceStandingNightID: nil,
        removedFromBoard: removedFromBoard
    )
}

@Suite("RepoLane's same-repository hold (OQ182)")
struct RepoLaneHoldTests {
    @Test("Every not-Done state holds: Blocked, Waiting on You, In Progress, Shelved and Todo")
    func everyNotDoneStateHolds() throws {
        for state: CardState in [.blocked, .waitingOnYou, .inProgress, .shelved, .todo] {
            let first = fixtureCard(id: 1, authoredOrder: 1, state: state)
            let second = fixtureCard(id: 2, authoredOrder: 2)
            let lane = RepoLane(repository: "backend", cards: [first, second])

            let holder = lane.holder(of: second) { $0 }
            #expect(holder?.id == first.id, "state \(state) should hold its sequence successor")
        }
    }

    @Test("A Done predecessor does not hold")
    func doneDoesNotHold() throws {
        let first = fixtureCard(id: 1, authoredOrder: 1, state: .done)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(repository: "backend", cards: [first, second])

        #expect(lane.holder(of: second) { $0 } == nil)
    }

    @Test("A predecessor removed from the board holds, whatever state it stood in when removed (OQ142)")
    func removedFromBoardHolds() throws {
        let first = fixtureCard(id: 1, authoredOrder: 1, state: .done, removedFromBoard: .archived)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(repository: "backend", cards: [first, second])

        #expect(lane.holder(of: second) { $0 }?.id == first.id)
    }

    @Test("An adopted Card never holds, and is never held by, a newly authored Card in the same lane")
    func adoptedAndNewlyAuthoredSequencesDoNotHoldEachOther() throws {
        // Card 1 is adopted; Cards 2 and 3 are newly authored.
        let adopted = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let newlyAuthoredFirst = fixtureCard(id: 2, authoredOrder: 2, state: .blocked)
        let newlyAuthoredSecond = fixtureCard(id: 3, authoredOrder: 3)
        let lane = RepoLane(
            repository: "backend", cards: [adopted, newlyAuthoredFirst, newlyAuthoredSecond],
            adoptedFrom: [adopted.id: "FEAT-OLD"]
        )

        // The newly authored Card's hold comes from the other newly authored Card, never the adopted one.
        #expect(lane.holder(of: newlyAuthoredSecond) { $0 }?.id == newlyAuthoredFirst.id)
        // The adopted Card has no sequence predecessor of its own, so nothing holds it from this lane.
        #expect(lane.holder(of: adopted) { $0 } == nil)
    }

    @Test("Cards adopted from two different previous Features do not hold each other")
    func differentAdoptionOriginsDoNotHoldEachOther() throws {
        let fromFeatureA = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let fromFeatureB = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(
            repository: "backend", cards: [fromFeatureA, fromFeatureB],
            adoptedFrom: [fromFeatureA.id: "FEAT-A", fromFeatureB.id: "FEAT-B"]
        )

        #expect(lane.holder(of: fromFeatureB) { $0 } == nil)
    }

    @Test("Cards adopted from the same previous Feature keep their old authored order as one sequence")
    func sameAdoptionOriginSharesOneSequence() throws {
        let first = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(
            repository: "backend", cards: [first, second], adoptedFrom: [first.id: "FEAT-OLD", second.id: "FEAT-OLD"]
        )

        #expect(lane.holder(of: second) { $0 }?.id == first.id)
    }

    @Test("holder(of:currentCard:) re-reads current state rather than trusting the lane's own snapshot")
    func holderReadsCurrentStateThroughTheClosure() throws {
        // The lane's own snapshot says Blocked (stale); the closure reports Done (current).
        let staleFirst = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let currentFirst = fixtureCard(id: 1, authoredOrder: 1, state: .done)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(repository: "backend", cards: [staleFirst, second])

        let holder = lane.holder(of: second) { card in card.id == staleFirst.id ? currentFirst : card }
        #expect(holder == nil)
    }

    @Test("sequencePredecessors returns only the earlier Cards of the same sequence, in authored order")
    func sequencePredecessorsIsScopedAndOrdered() throws {
        let adopted = fixtureCard(id: 1, authoredOrder: 1)
        let newlyAuthoredFirst = fixtureCard(id: 2, authoredOrder: 2)
        let newlyAuthoredSecond = fixtureCard(id: 3, authoredOrder: 3)
        let newlyAuthoredThird = fixtureCard(id: 4, authoredOrder: 4)
        let lane = RepoLane(
            repository: "backend", cards: [adopted, newlyAuthoredFirst, newlyAuthoredSecond, newlyAuthoredThird],
            adoptedFrom: [adopted.id: "FEAT-OLD"]
        )

        let predecessors = lane.sequencePredecessors(of: newlyAuthoredThird).map(\.id)
        #expect(predecessors == [newlyAuthoredFirst.id, newlyAuthoredSecond.id])
        #expect(lane.sequencePredecessors(of: newlyAuthoredFirst).isEmpty)
    }
}

// spec ruling OQ182 (2026-10-22), item 4: `RepoLane.heldCards(in:where:adoptedFrom:currentCard:)`, the one
// definition of "held" shared by the land trigger and the Partial Landing pull request body, as well
// as `CardAutoBlock.held`.

@Suite("RepoLane.heldCards (OQ182 item 4)")
struct RepoLaneHeldCardsTests {
    @Test("Only a Todo Card held by a not-Done predecessor is returned, paired with that predecessor")
    func onlyHeldTodoCardsArePaired() {
        let holder = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let held = fixtureCard(id: 2, authoredOrder: 2, state: .todo)
        let unheld = fixtureCard(id: 3, authoredOrder: 1, state: .todo, repository: "mobile")
        let cards = [holder, held, unheld]

        let result = RepoLane.heldCards(in: cards) { $0 }

        #expect(result.count == 1)
        #expect(result[0].card.id == held.id)
        #expect(result[0].holder.id == holder.id)
    }

    @Test("A Card already Blocked or Waiting on You is never returned, even behind a not-Done predecessor")
    func nonTodoCardsAreNeverHeld() {
        let holder = fixtureCard(id: 1, authoredOrder: 1, state: .todo)
        let blocked = fixtureCard(id: 2, authoredOrder: 2, state: .blocked)
        let waiting = fixtureCard(id: 3, authoredOrder: 3, state: .waitingOnYou)

        let result = RepoLane.heldCards(in: [holder, blocked, waiting]) { $0 }

        #expect(result.isEmpty)
    }

    @Test("A Todo Card removed from the board is never returned as held")
    func removedTodoCardIsNeverHeld() {
        let holder = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let removedHeld = fixtureCard(id: 2, authoredOrder: 2, state: .todo, removedFromBoard: .trashed)

        let result = RepoLane.heldCards(in: [holder, removedHeld]) { $0 }

        #expect(result.isEmpty)
    }

    @Test("A held Card whose predecessor is Shelved, or removed from the board, is still held")
    func shelvedOrRemovedPredecessorsStillHold() {
        let shelvedHolder = fixtureCard(id: 1, authoredOrder: 1, state: .shelved)
        let heldByShelved = fixtureCard(id: 2, authoredOrder: 2, state: .todo)
        let removedHolder = fixtureCard(
            id: 3, authoredOrder: 1, state: .done, removedFromBoard: .archived, repository: "mobile"
        )
        let heldByRemoved = fixtureCard(id: 4, authoredOrder: 2, state: .todo, repository: "mobile")

        let shelvedLane = RepoLane.heldCards(in: [shelvedHolder, heldByShelved]) { $0 }
        #expect(shelvedLane.map(\.card.id) == [heldByShelved.id])
        #expect(shelvedLane.first?.holder.id == shelvedHolder.id)

        let removedLane = RepoLane.heldCards(in: [removedHolder, heldByRemoved]) { $0 }
        #expect(removedLane.map(\.card.id) == [heldByRemoved.id])
        #expect(removedLane.first?.holder.id == removedHolder.id)
    }

    @Test("Several repositories' lanes are each considered, independently")
    func multipleRepositoriesAreEachConsidered() {
        let backendHolder = fixtureCard(id: 10, authoredOrder: 1, state: .blocked)
        let backendHeld = fixtureCard(id: 11, authoredOrder: 2, state: .todo)
        let mobileCard = fixtureCard(id: 12, authoredOrder: 1, state: .todo, repository: "mobile")

        let result = RepoLane.heldCards(in: [backendHolder, backendHeld, mobileCard]) { $0 }

        #expect(result.map(\.card.id) == [backendHeld.id])
    }

    @Test("currentCard re-reads live state, never trusting the given snapshot (OQ182 item 2)")
    func currentCardIsReReadThroughTheClosure() {
        let staleHolder = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let currentHolder = fixtureCard(id: 1, authoredOrder: 1, state: .done)
        let held = fixtureCard(id: 2, authoredOrder: 2, state: .todo)

        let result = RepoLane.heldCards(in: [staleHolder, held]) { card in
            card.id == staleHolder.id ? currentHolder : card
        }

        #expect(result.isEmpty)
    }

    @Test("The holder it pairs with names the Work Card to wait on by title")
    func pairedHolderCarriesItsOwnTitle() {
        let holder = fixtureCard(id: 1, authoredOrder: 1, state: .blocked, title: "Add the endpoint")
        let held = fixtureCard(id: 2, authoredOrder: 2, state: .todo, title: "Document the endpoint")

        let result = RepoLane.heldCards(in: [holder, held]) { $0 }

        #expect(result.first?.holder.displayTitle == "Add the endpoint")
        #expect(result.first?.card.displayTitle == "Document the endpoint")
    }
}
