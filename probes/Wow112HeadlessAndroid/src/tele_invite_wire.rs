pub const CMSG_GROUP_INVITE_OPCODE: u32 = 0x006E;

#[derive(Debug, Default)]
pub struct OneShotInviteGuard {
    attempted: bool,
}

impl OneShotInviteGuard {
    pub fn attempted(&self) -> bool {
        self.attempted
    }

    pub fn arm_attempt(&mut self) -> Result<(), &'static str> {
        if self.attempted {
            return Err("invite mutation already attempted; retry forbidden");
        }
        self.attempted = true;
        Ok(())
    }
}

pub fn encode_group_invite_target(target: &str) -> Result<Vec<u8>, String> {
    if target.is_empty() {
        return Err("invite target is empty".to_string());
    }
    if target.as_bytes().contains(&0) {
        return Err("invite target contains NUL".to_string());
    }
    if target.len() > 64 {
        return Err(format!("invite target too long: {} bytes", target.len()));
    }

    let mut payload = Vec::with_capacity(target.len() + 1);
    payload.extend_from_slice(target.as_bytes());
    payload.push(0);
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_invite_is_cstring() {
        assert_eq!(encode_group_invite_target("Somebody").unwrap(), b"Somebody\0");
    }

    #[test]
    fn guard_forbids_second_attempt() {
        let mut guard = OneShotInviteGuard::default();
        assert!(guard.arm_attempt().is_ok());
        assert!(guard.attempted());
        assert!(guard.arm_attempt().is_err());
    }
}
