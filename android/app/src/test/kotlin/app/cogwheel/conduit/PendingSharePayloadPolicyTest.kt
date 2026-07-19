package app.cogwheel.conduit

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingSharePayloadPolicyTest {
    @Test
    fun durablePayloadRequiresANonBlankAcknowledgementId() {
        assertNull(
            validatedPendingSharePayload(
                id = null,
                text = "hello",
                filePaths = emptyList()
            )
        )
        assertNull(
            validatedPendingSharePayload(
                id = "  ",
                text = "hello",
                filePaths = emptyList()
            )
        )
    }

    @Test
    fun durablePayloadRequiresContentAndNormalizesItsFields() {
        assertNull(
            validatedPendingSharePayload(
                id = "share-empty",
                text = "  ",
                filePaths = listOf("  ")
            )
        )

        val payload = validatedPendingSharePayload(
            id = " share-current ",
            text = " durable text ",
            filePaths = listOf(" /tmp/one.txt ", "")
        )
        assertNotNull(payload)
        assertEquals("share-current", payload!!["id"])
        assertEquals("durable text", payload["text"])
        assertEquals(listOf("/tmp/one.txt"), payload["filePaths"])
    }

    @Test
    fun inProgressImportFencesNewOwnershipUntilItsStagingFinishes() {
        val coordinator = PendingShareImportCoordinator()
        assertTrue(coordinator.begin("old") { true })

        var competingDurableBeginRan = false
        assertFalse(
            coordinator.begin("new") {
                competingDurableBeginRan = true
                true
            }
        )
        assertFalse(competingDurableBeginRan)

        var oldCommitRan = false
        assertEquals(
            PendingShareFinalization.COMMITTED,
            coordinator.finalizeIfCurrent("old") {
                oldCommitRan = true
                true
            }
        )
        assertTrue(oldCommitRan)
        assertTrue(coordinator.finishIfCurrent("old") {})
        assertTrue(coordinator.begin("new") { true })

        var staleCompletionRan = false
        assertFalse(
            coordinator.runIfCurrent("old") {
                staleCompletionRan = true
            }
        )
        assertFalse(staleCompletionRan)

        var staleCommitRan = false
        assertEquals(
            PendingShareFinalization.SUPERSEDED,
            coordinator.finalizeIfCurrent("old") {
                staleCommitRan = true
                true
            }
        )
        assertFalse(staleCommitRan)

        var currentCommitRan = false
        assertEquals(
            PendingShareFinalization.COMMITTED,
            coordinator.finalizeIfCurrent("new") {
                currentCommitRan = true
                true
            }
        )
        assertTrue(currentCommitRan)
    }

    @Test
    fun failedDurableBeginDoesNotReplaceTheCurrentImport() {
        val coordinator = PendingShareImportCoordinator()
        assertFalse(coordinator.begin("failed-first") { false })
        assertEquals(
            PendingShareFinalization.SUPERSEDED,
            coordinator.finalizeIfCurrent("failed-first") { true }
        )
        assertTrue(coordinator.begin("current") { true })
        var competingDurableBeginRan = false
        assertFalse(
            coordinator.begin("failed-successor") {
                competingDurableBeginRan = true
                false
            }
        )
        assertFalse(competingDurableBeginRan)

        var currentCommitRan = false
        assertEquals(
            PendingShareFinalization.COMMITTED,
            coordinator.finalizeIfCurrent("current") {
                currentCommitRan = true
                true
            }
        )
        assertTrue(currentCommitRan)

        var failedSuccessorCommitRan = false
        assertEquals(
            PendingShareFinalization.SUPERSEDED,
            coordinator.finalizeIfCurrent("failed-successor") {
                failedSuccessorCommitRan = true
                true
            }
        )
        assertFalse(failedSuccessorCommitRan)
    }

    @Test
    fun failedDurableFinalizeKeepsOwnershipForRecovery() {
        val coordinator = PendingShareImportCoordinator()
        assertTrue(coordinator.begin("current") { true })

        assertEquals(
            PendingShareFinalization.FAILED,
            coordinator.finalizeIfCurrent("current") { false }
        )
        assertEquals(
            PendingShareFinalization.COMMITTED,
            coordinator.finalizeIfCurrent("current") { true }
        )
    }

    @Test
    fun newerImportRetainsTheOlderPayloadUntilItsExactOrderedAcknowledgement() {
        fun idForRaw(raw: String): String? = raw.substringBefore(':').takeIf(String::isNotEmpty)

        var queue = PendingSharePayloadQueue(current = "old:/staging/old.txt")
        queue = queue.retireCurrent(
            replacementId = "new",
            idForRaw = ::idForRaw
        )
        assertEquals(listOf("old:/staging/old.txt"), queue.backlog)
        assertNull(queue.current)

        queue = queue.withCurrent("new:/staging/new.txt")
        assertEquals("old:/staging/old.txt", queue.peek()?.raw)

        val outOfOrder = queue.acknowledge("new", ::idForRaw)
        assertFalse(outOfOrder.acknowledged)
        assertEquals(queue, outOfOrder.queue)

        val wrong = queue.acknowledge("unrelated", ::idForRaw)
        assertFalse(wrong.acknowledged)
        assertEquals(queue, wrong.queue)

        val oldAcknowledgement = queue.acknowledge("old", ::idForRaw)
        assertTrue(oldAcknowledgement.acknowledged)
        assertTrue(oldAcknowledgement.queue.backlog.isEmpty())
        assertEquals("new:/staging/new.txt", oldAcknowledgement.queue.current)

        val newAcknowledgement = oldAcknowledgement.queue.acknowledge("new", ::idForRaw)
        assertTrue(newAcknowledgement.acknowledged)
        assertFalse(newAcknowledgement.queue.hasRecords)
    }

    @Test
    fun repeatedRetirementKeepsPayloadsInFifoOrderWithoutDuplicatingIds() {
        fun idForRaw(raw: String): String? = raw.substringBefore(':').takeIf(String::isNotEmpty)

        var queue = PendingSharePayloadQueue(current = "one:first")
            .retireCurrent(replacementId = "two", idForRaw = ::idForRaw)
            .withCurrent("two:second")
            .retireCurrent(replacementId = "three", idForRaw = ::idForRaw)
            .withCurrent("three:third")

        assertEquals(listOf("one:first", "two:second"), queue.backlog)
        assertEquals("three:third", queue.current)

        queue = queue.retireCurrent(replacementId = "three", idForRaw = ::idForRaw)
        assertEquals(listOf("one:first", "two:second"), queue.backlog)
        assertNull(queue.current)
    }

    @Test
    fun malformedHeadCanBeRemovedWithoutDroppingLaterPayloads() {
        val queue = PendingSharePayloadQueue(
            backlog = listOf("malformed", "valid:older"),
            current = "newest:current"
        )
        val malformed = queue.peek()
        assertNotNull(malformed)

        val recovered = queue.removing(malformed!!)
        assertEquals("valid:older", recovered.peek()?.raw)
        assertEquals("newest:current", recovered.current)
    }

    @Test
    fun recordBudgetRejectsNewPayloadWithoutEvictingExistingRecords() {
        val queue = PendingSharePayloadQueue(
            backlog = listOf("one"),
            current = "two"
        )

        val admission = queue.admitCurrent(
            raw = "three",
            replacementId = "three",
            idForRaw = { it },
            stagedBytesForRaw = { 1L },
            maxRecords = 2,
            maxStagedBytes = 10L
        )

        assertFalse(admission.admitted)
        assertEquals(listOf("one", "two"), admission.queue.backlog)
        assertNull(admission.queue.current)
    }

    @Test
    fun stagedByteBudgetRejectsNewPayloadWithoutEvictingExistingRecords() {
        val queue = PendingSharePayloadQueue(backlog = listOf("older"))

        val admission = queue.admitCurrent(
            raw = "newer",
            replacementId = "newer",
            idForRaw = { it },
            stagedBytesForRaw = { record ->
                when (record) {
                    "older" -> 6L
                    "newer" -> 5L
                    else -> null
                }
            },
            maxRecords = 2,
            maxStagedBytes = 10L
        )

        assertFalse(admission.admitted)
        assertEquals(queue, admission.queue)
    }

    @Test
    fun payloadAtBothAdmissionLimitsIsAccepted() {
        val queue = PendingSharePayloadQueue(backlog = listOf("older"))

        val admission = queue.admitCurrent(
            raw = "newer",
            replacementId = "newer",
            idForRaw = { it },
            stagedBytesForRaw = { 5L },
            maxRecords = 2,
            maxStagedBytes = 10L
        )

        assertTrue(admission.admitted)
        assertEquals(listOf("older"), admission.queue.backlog)
        assertEquals("newer", admission.queue.current)
    }

    @Test
    fun unknownLengthGenericStreamIsBoundedAndItsPartialFileIsRemoved() {
        val root = Files.createTempDirectory("conduit-share-stream-")
        try {
            val destination = root.resolve("generic.bin").toFile()
            val input = UnknownLengthChunkedInputStream(
                bytes = "abcdef".toByteArray(),
                maximumChunkSize = 3
            )

            assertNull(
                copySharedStreamToFileWithinLimit(
                    input = input,
                    destination = destination,
                    maximumBytes = 4L
                )
            )
            assertFalse(destination.exists())
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun unknownLengthGenericStreamAtTheLimitIsAccepted() {
        val root = Files.createTempDirectory("conduit-share-stream-limit-")
        try {
            val destination = root.resolve("generic.bin").toFile()
            val input = UnknownLengthChunkedInputStream(
                bytes = "abcdef".toByteArray(),
                maximumChunkSize = 2
            )

            assertEquals(
                6L,
                copySharedStreamToFileWithinLimit(
                    input = input,
                    destination = destination,
                    maximumBytes = 6L
                )
            )
            assertEquals("abcdef", destination.readText())
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun existingStagingBytesReduceTheAggregateStreamingBudget() {
        val root = Files.createTempDirectory("conduit-share-aggregate-")
        try {
            Files.write(root.resolve("existing.bin"), ByteArray(6) { 1 })
            val remaining = remainingSharedStagingBytes(
                stagingRoot = root.toFile(),
                maximumBytes = 10L,
                noFollowRegularFileSize = { candidate ->
                    if (Files.isRegularFile(candidate.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                        Files.size(candidate.toPath())
                    } else {
                        null
                    }
                }
            )
            assertEquals(4L, remaining)

            val destination = root.resolve("new.bin").toFile()
            assertNull(
                copySharedStreamToFileWithinLimit(
                    input = UnknownLengthChunkedInputStream(
                        bytes = ByteArray(5) { 2 },
                        maximumChunkSize = 2
                    ),
                    destination = destination,
                    maximumBytes = remaining!!
                )
            )
            assertFalse(destination.exists())
            assertEquals(6L, Files.size(root.resolve("existing.bin")))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun importPrefixCleanupRemovesOnlyExactRegularDirectChildren() {
        val root = Files.createTempDirectory("conduit-share-restart-")
        val importId = "7f834a7a-46fb-49bb-9dc8-c1f2c39d44db"
        val otherId = "ef97cd22-f1e1-4b37-b940-655f79d7e934"
        try {
            val prefix = shareImportStagingFilePrefix(importId)!!
            val owned = root.resolve("${prefix}0-owned.txt")
            val other = root.resolve("${shareImportStagingFilePrefix(otherId)}0-other.txt")
            val nested = root.resolve("nested").resolve("${prefix}1-nested.txt")
            Files.write(owned, "owned".toByteArray())
            Files.write(other, "other".toByteArray())
            Files.createDirectories(nested.parent)
            Files.write(nested, "nested".toByteArray())

            assertTrue(
                cleanupInterruptedShareImportFiles(
                    stagingRoot = root.toFile(),
                    importId = importId,
                    isRegularFileNoFollow = { candidate ->
                        Files.isRegularFile(
                            candidate.toPath(),
                            LinkOption.NOFOLLOW_LINKS
                        )
                    }
                )
            )
            assertFalse(Files.exists(owned))
            assertTrue(Files.exists(other))
            assertTrue(Files.exists(nested))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun interruptedStatusIsTerminalizedOnlyForACanonicalLiveImportId() {
        val status = PendingShareImportStatusState(
            id = "7F834A7A-46FB-49BB-9DC8-C1F2C39D44DB",
            expectedFileCount = 2,
            isInProgress = true,
            errors = listOf("Earlier warning")
        )

        val terminal = interruptedShareImportStatus(status)
        assertNotNull(terminal)
        assertEquals("7f834a7a-46fb-49bb-9dc8-c1f2c39d44db", terminal!!.id)
        assertEquals(2, terminal.expectedFileCount)
        assertFalse(terminal.isInProgress)
        assertEquals(
            listOf("Earlier warning", INTERRUPTED_SHARE_IMPORT_MESSAGE),
            terminal.errors
        )
        assertNull(interruptedShareImportStatus(status.copy(isInProgress = false)))
        assertNull(interruptedShareImportStatus(status.copy(id = "not-a-uuid")))
    }

    @Test
    fun restartReconciliationCannotRunWhileAProcessWideWorkerIsLive() {
        val coordinator = PendingShareImportCoordinator()
        assertTrue(coordinator.begin("live") { true })
        var cleanupRan = false

        assertFalse(
            coordinator.reconcileIfIdle {
                cleanupRan = true
                true
            }
        )
        assertFalse(cleanupRan)

        assertTrue(coordinator.finishIfCurrent("live") {})
        assertTrue(
            coordinator.reconcileIfIdle {
                cleanupRan = true
                true
            }
        )
        assertTrue(cleanupRan)
    }

    @Test
    fun importRuntimeKeepsCoordinatorAndExecutorAtProcessScope() {
        assertSame(
            PendingShareImportRuntime.coordinator,
            PendingShareImportRuntime.coordinator
        )
        assertSame(
            PendingShareImportRuntime.executor,
            PendingShareImportRuntime.executor
        )
    }

    @Test
    fun ownershipCannotChangeDuringTheDurableFinalize() {
        val coordinator = PendingShareImportCoordinator()
        assertTrue(coordinator.begin("old") { true })

        val finalizeEntered = CountDownLatch(1)
        val releaseFinalize = CountDownLatch(1)
        val beginReachedOwnershipBoundary = CountDownLatch(1)
        val releaseBeginToOwnershipMonitor = CountDownLatch(1)
        val beginLeavingBoundary = CountDownLatch(1)
        val beginThread = AtomicReference<Thread>()
        val executor = Executors.newFixedThreadPool(2)
        try {
            val finalizeFuture = executor.submit<PendingShareFinalization> {
                coordinator.finalizeIfCurrent("old") {
                    finalizeEntered.countDown()
                    check(releaseFinalize.await(5, TimeUnit.SECONDS))
                    true
                }
            }
            assertTrue(finalizeEntered.await(5, TimeUnit.SECONDS))

            val beginFuture = executor.submit<Boolean> {
                coordinator.begin(
                    id = "new",
                    onBeforeOwnershipLock = {
                        beginThread.set(Thread.currentThread())
                        beginReachedOwnershipBoundary.countDown()
                        check(releaseBeginToOwnershipMonitor.await(5, TimeUnit.SECONDS))
                        beginLeavingBoundary.countDown()
                    }
                ) { true }
            }
            assertTrue(beginReachedOwnershipBoundary.await(5, TimeUnit.SECONDS))
            releaseBeginToOwnershipMonitor.countDown()
            assertTrue(beginLeavingBoundary.await(5, TimeUnit.SECONDS))

            val blockedDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (beginThread.get()?.state != Thread.State.BLOCKED &&
                System.nanoTime() < blockedDeadline
            ) {
                Thread.yield()
            }
            assertEquals(Thread.State.BLOCKED, beginThread.get()?.state)
            assertFalse(beginFuture.isDone)

            releaseFinalize.countDown()
            assertEquals(
                PendingShareFinalization.COMMITTED,
                finalizeFuture.get(5, TimeUnit.SECONDS)
            )
            assertFalse(beginFuture.get(5, TimeUnit.SECONDS))
            assertTrue(coordinator.finishIfCurrent("old") {})
            assertTrue(coordinator.begin("new") { true })
            assertEquals(
                PendingShareFinalization.SUPERSEDED,
                coordinator.finalizeIfCurrent("old") { true }
            )
        } finally {
            releaseBeginToOwnershipMonitor.countDown()
            releaseFinalize.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun ownedCleanupPolicyAcceptsOnlyCanonicalDirectChildren() {
        val root = Files.createTempDirectory("conduit-owned-share-")
        val sibling = Files.createTempDirectory("conduit-unowned-share-")
        try {
            val direct = root.resolve("owned.txt")
            val nested = root.resolve("nested").resolve("not-direct.txt")
            val unrelated = sibling.resolve("unowned.txt")
            Files.write(direct, "owned".toByteArray())
            Files.createDirectories(nested.parent)
            Files.write(nested, "nested".toByteArray())
            Files.write(unrelated, "unowned".toByteArray())

            assertTrue(isCanonicalDirectChild(direct.toString(), root.toString()))
            assertFalse(isCanonicalDirectChild(nested.toString(), root.toString()))
            assertFalse(isCanonicalDirectChild(unrelated.toString(), root.toString()))

            val outsideLink = root.resolve("outside-link.txt")
            try {
                Files.createSymbolicLink(outsideLink, unrelated)
                assertFalse(
                    isCanonicalDirectChild(outsideLink.toString(), root.toString())
                )
            } catch (_: UnsupportedOperationException) {
                // Some host filesystems disallow symlinks; the canonical
                // sibling and nesting checks above still exercise confinement.
            } catch (_: IOException) {
                // Sandboxed and policy-restricted hosts can reject symlink
                // creation even when the filesystem supports the operation.
            }
        } finally {
            root.toFile().deleteRecursively()
            sibling.toFile().deleteRecursively()
        }
    }

    private class UnknownLengthChunkedInputStream(
        bytes: ByteArray,
        private val maximumChunkSize: Int
    ) : InputStream() {
        private val delegate = ByteArrayInputStream(bytes)

        init {
            require(maximumChunkSize > 0)
        }

        override fun read(): Int = delegate.read()

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            delegate.read(buffer, offset, minOf(length, maximumChunkSize))

        // ContentResolver providers frequently cannot report a length up front.
        override fun available(): Int = 0
    }
}
