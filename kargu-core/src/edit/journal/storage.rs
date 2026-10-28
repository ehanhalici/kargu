//! Private fd-rooted journal IO. No original editor file is opened for writing.
use super::{
    Envelope, GENESIS, JournalDirectory, JournalIssue, Payload, RecordDigest, Sequence, Version,
    digest,
};
use crate::{
    constants::limits,
    error::CoreError,
    security::file::{Revision, checkpoint},
};
use nix::{
    fcntl::{AtFlags, Flock, FlockArg, OFlag, open, openat},
    sys::stat::{Mode, fstatat},
};
use std::{
    fs::File,
    io::{Read, Write},
    os::{fd::AsRawFd, unix::fs::MetadataExt},
    path::{Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

const IO_BYTES: usize = 4096;

struct Directory {
    path: PathBuf,
    held: File,
}
fn os_error(error: nix::errno::Errno) -> CoreError {
    std::io::Error::from(error).into()
}
fn lock(file: File, operation: FlockArg) -> Result<Flock<File>, CoreError> {
    Flock::lock(file, operation).map_err(|(_, error)| {
        if error == nix::errno::Errno::EWOULDBLOCK {
            CoreError::Busy
        } else {
            os_error(error)
        }
    })
}
impl Directory {
    fn open(directory: JournalDirectory) -> Result<Self, CoreError> {
        if std::fs::symlink_metadata(&directory.0)?
            .file_type()
            .is_symlink()
        {
            return Err(CoreError::Rejected);
        }
        let path = directory.0.canonicalize()?;
        let held = File::from(
            open(
                &path,
                OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
                Mode::empty(),
            )
            .map_err(os_error)?,
        );
        let result = Self { path, held };
        result.revalidate()?;
        Ok(result)
    }
    fn revalidate(&self) -> Result<(), CoreError> {
        let held = self.held.metadata()?;
        let named = std::fs::symlink_metadata(&self.path)?;
        if !held.is_dir()
            || !named.is_dir()
            || held.mode() & 0o7777 != 0o700
            || held.uid() != nix::unistd::geteuid().as_raw()
            || held.dev() != named.dev()
            || held.ino() != named.ino()
        {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(())
    }
    fn check_file(&self, file: &File, name: &Path) -> Result<(), CoreError> {
        self.revalidate()?;
        let held = file.metadata()?;
        let named = fstatat(&self.held, name, AtFlags::AT_SYMLINK_NOFOLLOW).map_err(os_error)?;
        if !held.is_file()
            || held.uid() != nix::unistd::geteuid().as_raw()
            || held.mode() & 0o7777 != 0o600
            || held.nlink() != 1
            || held.dev() != named.st_dev
            || held.ino() != named.st_ino
        {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(())
    }
}
fn name(id: &crate::edit::types::EditorEditId) -> PathBuf {
    PathBuf::from(format!("{}.ndjson", String::from(id.clone())))
}
struct WrittenBytes(usize);
impl WrittenBytes {
    fn include(&mut self, bytes: usize) -> Result<(), CoreError> {
        let next = self
            .0
            .checked_add(bytes)
            .ok_or(CoreError::ArithmeticOverflow)?;
        if next > limits::EDIT_JOURNAL_BYTES {
            return Err(CoreError::Limit);
        }
        self.0 = next;
        Ok(())
    }
}
pub(super) struct Writer {
    directory: Directory,
    file: Flock<File>,
    name: PathBuf,
    id: crate::edit::types::EditorEditId,
    sequence: Sequence,
    digest: RecordDigest,
    written: WrittenBytes,
    revision: Revision,
}
impl Writer {
    pub(super) fn create(
        directory: JournalDirectory,
        issue: JournalIssue,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<Self, CoreError> {
        checkpoint(cancel, deadline)?;
        let directory = Directory::open(directory)?;
        if directory.path.starts_with(&issue.workspace) {
            return Err(CoreError::Rejected);
        }
        let name = name(&issue.id);
        let file = File::from(
            openat(
                &directory.held,
                &name,
                OFlag::O_RDWR
                    | OFlag::O_APPEND
                    | OFlag::O_CREAT
                    | OFlag::O_EXCL
                    | OFlag::O_NOFOLLOW
                    | OFlag::O_NONBLOCK
                    | OFlag::O_CLOEXEC,
                Mode::S_IRUSR | Mode::S_IWUSR,
            )
            .map_err(|error| {
                if error == nix::errno::Errno::EEXIST {
                    CoreError::AlreadyCompleted
                } else {
                    os_error(error)
                }
            })?,
        );
        let mut file = lock(file, FlockArg::LockExclusiveNonblock)?;
        directory.check_file(&file, &name)?;
        let sequence = Sequence::try_from(1)?;
        let id = issue.id.clone();
        let payload = Payload::Issue {
            issue: Box::new(issue),
        };
        let mut written = WrittenBytes(0);
        let digest = write_record(
            &mut file,
            Record {
                directory: &directory,
                sequence,
                previous: GENESIS,
                payload,
            },
            &mut written,
            cancel,
            deadline,
        )?;
        directory.check_file(&file, &name)?;
        let revision = Revision::from(file.metadata()?);
        Ok(Self {
            directory,
            file,
            name,
            id,
            sequence,
            digest,
            written,
            revision,
        })
    }
    pub(super) fn id(&self) -> &crate::edit::types::EditorEditId {
        &self.id
    }
    pub(super) fn append(
        &mut self,
        payload: Payload,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<(), CoreError> {
        checkpoint(cancel, deadline)?;
        self.directory.check_file(&self.file, &self.name)?;
        if Revision::from(self.file.metadata()?) != self.revision {
            return Err(CoreError::WorkspaceChanged);
        }
        let sequence = self.sequence.next()?;
        let digest = write_record(
            &mut self.file,
            Record {
                directory: &self.directory,
                sequence,
                previous: self.digest,
                payload,
            },
            &mut self.written,
            cancel,
            deadline,
        )?;
        self.directory.check_file(&self.file, &self.name)?;
        self.revision = Revision::from(self.file.metadata()?);
        self.sequence = sequence;
        self.digest = digest;
        Ok(())
    }
}
struct Record<'a> {
    sequence: Sequence,
    previous: RecordDigest,
    payload: Payload,
    directory: &'a Directory,
}
fn write_record(
    file: &mut File,
    record: Record<'_>,
    written: &mut WrittenBytes,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<RecordDigest, CoreError> {
    let checksum = digest(record.sequence, record.previous, &record.payload)?;
    let envelope = Envelope {
        version: Version,
        sequence: record.sequence,
        previous: record.previous,
        payload: record.payload,
        digest: checksum,
    };
    let mut bytes = serde_json::to_vec(&envelope).map_err(|_| CoreError::InvalidToolOutput)?;
    if bytes.len() > limits::EDIT_JOURNAL_RECORD_BYTES {
        return Err(CoreError::Limit);
    }
    bytes.push(b'\n');
    written.include(bytes.len())?;
    for chunk in bytes.chunks(IO_BYTES) {
        checkpoint(cancel, deadline)?;
        file.write_all(chunk)?;
    }
    checkpoint(cancel, deadline)?;
    file.sync_all()?;
    record.directory.held.sync_all()?;
    checkpoint(cancel, deadline)?;
    Ok(checksum)
}
pub(super) fn read(
    directory: JournalDirectory,
    id: &crate::edit::types::EditorEditId,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<Vec<u8>, CoreError> {
    checkpoint(cancel, deadline)?;
    let directory = Directory::open(directory)?;
    let name = name(id);
    let pin = File::from(
        openat(
            &directory.held,
            &name,
            OFlag::O_PATH | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(os_error)?,
    );
    directory.check_file(&pin, &name)?;
    let held_path = PathBuf::from(format!("/proc/self/fd/{}", pin.as_raw_fd()));
    let file = File::from(
        open(
            &held_path,
            OFlag::O_RDONLY | OFlag::O_NONBLOCK | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(os_error)?,
    );
    let file = lock(file, FlockArg::LockSharedNonblock)?;
    directory.check_file(&file, &name)?;
    let metadata = file.metadata()?;
    let size = usize::try_from(metadata.len()).map_err(|_| CoreError::Limit)?;
    if size > limits::EDIT_JOURNAL_BYTES {
        return Err(CoreError::Limit);
    }
    let revision = Revision::from(metadata);
    let mut reader = &*file;
    let mut output = Vec::with_capacity(size);
    let mut buffer = [0; IO_BYTES];
    loop {
        checkpoint(cancel, deadline)?;
        let bytes = reader.read(&mut buffer)?;
        if bytes == 0 {
            break;
        }
        let end = output
            .len()
            .checked_add(bytes)
            .ok_or(CoreError::ArithmeticOverflow)?;
        if end > limits::EDIT_JOURNAL_BYTES {
            return Err(CoreError::Limit);
        }
        output.extend_from_slice(buffer.get(..bytes).ok_or(CoreError::Limit)?);
    }
    checkpoint(cancel, deadline)?;
    directory.check_file(&file, &name)?;
    if Revision::from(file.metadata()?) != revision {
        return Err(CoreError::WorkspaceChanged);
    }
    Ok(output)
}
