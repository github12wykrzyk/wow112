#[cfg(windows)]
mod imp {
    use std::ffi::c_void;
    use std::mem::{size_of, zeroed};
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;

    type Handle = *mut c_void;
    type Bool = i32;
    type Dword = u32;
    type SizeT = usize;
    type UlongPtr = usize;

    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: i32 = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: Dword = 0x0000_2000;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct JobObjectBasicLimitInformation {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: Dword,
        minimum_working_set_size: SizeT,
        maximum_working_set_size: SizeT,
        active_process_limit: Dword,
        affinity: UlongPtr,
        priority_class: Dword,
        scheduling_class: Dword,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct JobObjectExtendedLimitInformation {
        basic_limit_information: JobObjectBasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: SizeT,
        job_memory_limit: SizeT,
        peak_process_memory_used: SizeT,
        peak_job_memory_used: SizeT,
    }

    #[link(name = "Kernel32")]
    extern "system" {
        fn CreateJobObjectW(attributes: *mut c_void, name: *const u16) -> Handle;
        fn SetInformationJobObject(
            job: Handle,
            info_class: i32,
            info: *mut c_void,
            info_length: Dword,
        ) -> Bool;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> Bool;
        fn CloseHandle(handle: Handle) -> Bool;
        fn GetLastError() -> Dword;
    }

    #[derive(Debug)]
    pub struct KillOnCloseJob {
        handle: Handle,
    }

    impl KillOnCloseJob {
        pub fn new() -> Result<Self, String> {
            let handle = unsafe { CreateJobObjectW(std::ptr::null_mut(), std::ptr::null()) };
            if handle.is_null() {
                return Err(format!(
                    "CreateJobObjectW failed win32={}",
                    unsafe { GetLastError() }
                ));
            }

            let mut info: JobObjectExtendedLimitInformation = unsafe { zeroed() };
            info.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = unsafe {
                SetInformationJobObject(
                    handle,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    &mut info as *mut _ as *mut c_void,
                    size_of::<JobObjectExtendedLimitInformation>() as Dword,
                )
            };
            if ok == 0 {
                let error = unsafe { GetLastError() };
                unsafe {
                    CloseHandle(handle);
                }
                return Err(format!(
                    "SetInformationJobObject(KILL_ON_JOB_CLOSE) failed win32={error}"
                ));
            }
            Ok(Self { handle })
        }

        pub fn assign_child(&self, child: &Child) -> Result<(), String> {
            let process = child.as_raw_handle() as Handle;
            let ok = unsafe { AssignProcessToJobObject(self.handle, process) };
            if ok == 0 {
                return Err(format!(
                    "AssignProcessToJobObject pid={} failed win32={}",
                    child.id(),
                    unsafe { GetLastError() }
                ));
            }
            Ok(())
        }
    }

    impl Drop for KillOnCloseJob {
        fn drop(&mut self) {
            if !self.handle.is_null() {
                unsafe {
                    CloseHandle(self.handle);
                }
                self.handle = std::ptr::null_mut();
            }
        }
    }

    unsafe impl Send for KillOnCloseJob {}
}

#[cfg(not(windows))]
mod imp {
    use std::process::Child;

    #[derive(Debug, Default)]
    pub struct KillOnCloseJob;

    impl KillOnCloseJob {
        pub fn new() -> Result<Self, String> {
            Ok(Self)
        }

        pub fn assign_child(&self, _child: &Child) -> Result<(), String> {
            Ok(())
        }
    }
}

pub use imp::KillOnCloseJob;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn containment_object_can_be_created() {
        let _job = KillOnCloseJob::new().expect("kill-on-close containment must initialize");
    }
}
