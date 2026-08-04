from app.memory.contracts import MemoryState

from tests.contract.test_memory_delete import NOW, delete_command, ready_record


def test_backup_snapshot_cannot_resurrect_tombstoned_record() -> None:
    service, repo, context, _, memory_id = ready_record()
    backup = repo.record_for(tenant_id="tenant-a", principal_id="user-a", purpose="itinerary.personalization", memory_type="dietary_requirement")
    assert backup is not None and backup.state is MemoryState.ACTIVE
    service.delete_memory(command=delete_command(memory_id), context=context, now=NOW)
    assert repo.restore_record(backup) is None
    restored = repo.record_for(tenant_id="tenant-a", principal_id="user-a", purpose="itinerary.personalization", memory_type="dietary_requirement")
    assert restored is not None and restored.state is MemoryState.DELETED


def test_delete_replay_is_idempotent_and_outbox_is_not_duplicated() -> None:
    service, repo, context, _, memory_id = ready_record()
    command = delete_command(memory_id)
    first = service.delete_memory(command=command, context=context, now=NOW)
    replay = service.delete_memory(command=command, context=context, now=NOW)
    assert replay.replayed and replay.memory_id == first.memory_id
    assert len([event for event in repo.outbox_events if event.event_type == "memory.deleted"]) == 1


def test_deleted_record_cannot_be_exported_after_restore_attempt() -> None:
    service, repo, context, consent, memory_id = ready_record()
    backup = repo.record_for(tenant_id="tenant-a", principal_id="user-a", purpose="itinerary.personalization", memory_type="dietary_requirement")
    service.delete_memory(command=delete_command(memory_id), context=context, now=NOW)
    assert backup is not None and repo.restore_record(backup) is None
    assert service.export_memories(consent=consent, context=context, now=NOW).records == ()
