import os
import time

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

from indexer import (
    SUPPORTED_EXTENSIONS,
    delete_file_from_index,
    index_single_file,
    should_skip_path,
)

last_indexed = {}


def should_index(path):
    now = time.time()
    if path in last_indexed and now - last_indexed[path] < 2:
        return False
    last_indexed[path] = now
    return True


class FileChangeHandler(FileSystemEventHandler):

    def process_file(self, path):
        try:
            path = path.strip()
            if should_skip_path(path):
                return

            ext = os.path.splitext(path)[1].lower()
            if ext not in SUPPORTED_EXTENSIONS:
                return

            if not should_index(path):
                return

            print(f"INDEXING: {path}")
            index_single_file(path)
            print(f"INDEXED: {path}")

        except Exception as e:
            print(f"INDEX ERROR: {path}")
            print(e)

    def on_created(self, event):
        if event.is_directory:
            return
        print(f"NEW FILE: {event.src_path}")
        self.process_file(event.src_path)

    def on_modified(self, event):
        if event.is_directory:
            return
        print(f"MODIFIED: {event.src_path}")
        self.process_file(event.src_path)

    def on_deleted(self, event):
        if event.is_directory:
            return
        print(f"DELETED: {event.src_path}")
        delete_file_from_index(event.src_path)

    def on_moved(self, event):
        if event.is_directory:
            return
        print(f"MOVED: {event.src_path} -> {event.dest_path}")
        delete_file_from_index(event.src_path)
        self.process_file(event.dest_path)


def start_watcher(folder):
    event_handler = FileChangeHandler()
    observer = Observer()
    observer.schedule(event_handler, folder, recursive=True)
    observer.start()
    print(f"Watching folder: {folder}")
    return observer


def start_watchers(folders):
    observers = []
    for folder in folders:
        if os.path.isdir(folder):
            observers.append(start_watcher(folder))
    return observers


def stop_watcher(observer):
    if observer:
        observer.stop()
        observer.join()
        print("Watcher stopped")


def stop_watchers(observers):
    for observer in observers:
        stop_watcher(observer)
