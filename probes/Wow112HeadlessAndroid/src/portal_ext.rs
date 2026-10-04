const CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1;
const SUMMONING_PORTAL_ENTRY_HEADLESS: i32 = 36727;
const GAMEOBJECT_TYPE_RITUAL_HEADLESS: i32 = 18;
const PORTAL_RETRY_GAP_MS: u64 = 120;
const PORTAL_MAX_ATTEMPTS: u8 = 8;

fn update_mask_is_summoning_portal(mask: &UpdateMask) -> bool {
    match mask {
        UpdateMask::GameObject(go) => {
            let entry = go.object_entry().map(|v| v == SUMMONING_PORTAL_ENTRY_HEADLESS).unwrap_or(false);
            let ritual = go.gameobject_type_id().map(|v| v == GAMEOBJECT_TYPE_RITUAL_HEADLESS).unwrap_or(false);
            entry || ritual
        }
        _ => false,
    }
}

fn collect_summoning_portals(objects: &[Object], portals: &mut HashSet<u64>) {
    for object in objects {
        let guid = match object {
            Object::Values { guid1, mask1 } if update_mask_is_summoning_portal(mask1) => Some(guid1.guid()),
            Object::CreateObject { guid3, mask2, .. } | Object::CreateObject2 { guid3, mask2, .. }
                if update_mask_is_summoning_portal(mask2) => Some(guid3.guid()),
            _ => None,
        };
        if let Some(guid) = guid {
            if portals.insert(guid) { println!("[PORTAL] valid portal guid=0x{guid:016X}"); }
        }
    }
}

fn inspect_portal_update(opcode: u16, payload: &[u8], portals: &mut HashSet<u64>) -> Result<(), String> {
    if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE { return Ok(()); }
    let message = match parse_raw_server_message(opcode, payload) {
        Ok(v) => v,
        Err(e) => { println!("[PORTAL-DIAG] update skipped: {e}"); return Ok(()); }
    };
    match message {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(v) => collect_summoning_portals(&v.objects, portals),
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(v) => collect_summoning_portals(&v.objects, portals),
        _ => {}
    }
    Ok(())
}

fn portal_loop(stream: &mut TcpStream, crypto: &mut HeaderCrypto, soak_seconds: u64) -> Result<(), String> {
    stream.set_read_timeout(Some(Duration::from_millis(1000))).map_err(|e| format!("portal poll timeout: {e}"))?;
    let started = Instant::now();
    let mut portals = HashSet::new();
    let mut attempts = std::collections::HashMap::<u64,(u8,Instant)>::new();
    let mut next_ping = Instant::now();
    let mut pending_ping: Option<(u32,Instant)> = None;
    let mut seq = 1u32;
    println!("[PORTAL] ACTIVE entry=36727 ritual=18 CMSG_GAMEOBJ_USE=0x00B1");
    loop {
        if soak_seconds != 0 && started.elapsed() >= Duration::from_secs(soak_seconds) { return Ok(()); }
        if let Some((id, sent)) = pending_ping {
            if sent.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) { return Err(format!("world keepalive pong timeout ping={id}")); }
        } else if Instant::now() >= next_ping {
            let mut p = Vec::with_capacity(8); p.extend_from_slice(&seq.to_le_bytes()); p.extend_from_slice(&0u32.to_le_bytes());
            write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &p)?;
            pending_ping = Some((seq,Instant::now())); seq = seq.wrapping_add(1);
        }
        let now = Instant::now();
        for guid in portals.iter().copied().collect::<Vec<_>>() {
            let state = attempts.entry(guid).or_insert((0, now - Duration::from_millis(PORTAL_RETRY_GAP_MS)));
            if state.0 < PORTAL_MAX_ATTEMPTS && state.1.elapsed() >= Duration::from_millis(PORTAL_RETRY_GAP_MS) {
                write_encrypted_raw(stream, crypto.encrypter(), CMSG_GAMEOBJ_USE_OPCODE, &guid.to_le_bytes())?;
                state.0 += 1; state.1 = Instant::now();
                println!("[PORTAL] use guid=0x{guid:016X} attempt={}/{}", state.0, PORTAL_MAX_ATTEMPTS);
            }
        }
        let mut probe=[0u8;4];
        match stream.peek(&mut probe) {
            Ok(0) => return Err("world socket closed during portal-clicker session".to_string()),
            Ok(n) if n < 4 => thread::sleep(Duration::from_millis(10)),
            Ok(_) => {
                stream.set_read_timeout(Some(Duration::from_secs(20))).map_err(|e| format!("portal packet timeout: {e}"))?;
                let (opcode,payload)=read_encrypted_raw(stream,crypto.decrypter())?;
                stream.set_read_timeout(Some(Duration::from_millis(1000))).map_err(|e| format!("portal restore timeout: {e}"))?;
                if opcode==SMSG_PONG_OPCODE && payload.len()>=4 {
                    let id=u32::from_le_bytes(payload[0..4].try_into().unwrap());
                    if pending_ping.map(|v|v.0)==Some(id) { pending_ping=None; next_ping=Instant::now()+Duration::from_secs(PING_INTERVAL_SECONDS); }
                } else { inspect_portal_update(opcode,&payload,&mut portals)?; }
            }
            Err(e) if matches!(e.kind(),io::ErrorKind::WouldBlock|io::ErrorKind::TimedOut) => {}
            Err(e) => return Err(format!("portal world peek failed: {e:?}")),
        }
    }
}

pub fn login_portal(stream:&mut TcpStream,session_key:[u8;SESSION_KEY_LENGTH as usize],server_id:u8,username:&str,character_name:Option<&str>,soak_seconds:u64)->Result<(),String>{
    stream.set_read_timeout(Some(Duration::from_secs(20))).map_err(|e|format!("set world read timeout failed: {e}"))?;
    let challenge=expect_server_message::<SMSG_AUTH_CHALLENGE,_>(&mut *stream).map_err(|e|format!("read world auth challenge failed: {e:?}"))?;
    let seed=ProofSeed::new(); let seed_value=seed.seed();
    let normalized=NormalizedString::new(username).map_err(|e|format!("invalid account name: {e:?}"))?;
    let (proof,mut crypto)=seed.into_client_header_crypto(&normalized,session_key,challenge.server_seed);
    let auth=CMSG_AUTH_SESSION{build:OCTOWOW_WORLD_BUILD,server_id:server_id as u32,username:username.to_string(),client_seed:seed_value,client_proof:proof,addon_info:octo_fingerprint_addons()};
    let mut wire=Vec::new(); auth.write_unencrypted_client(&mut wire).map_err(|e|format!("encode auth: {e:?}"))?;
    stream.write_all(&wire).map_err(|e|format!("write auth: {e:?}"))?; skip_octowow_addon_info(stream,crypto.decrypter())?;
    let mut ok=false; for _ in 0..16 { let op=ServerOpcodeMessage::read_encrypted(&mut *stream,crypto.decrypter()).map_err(|e|format!("pre-auth: {e:?}"))?; if let ServerOpcodeMessage::SMSG_AUTH_RESPONSE(r)=op { if matches!(*r,SMSG_AUTH_RESPONSE::AuthOk{..}) {ok=true;} break; } }
    if !ok { return Err("world auth rejected".to_string()); }
    CMSG_CHAR_ENUM{}.write_encrypted_client(&mut *stream,crypto.encrypter()).map_err(|e|format!("char enum write: {e:?}"))?;
    let chars=expect_server_message_encryption::<SMSG_CHAR_ENUM,_>(&mut *stream,crypto.decrypter()).map_err(|e|format!("char enum read: {e:?}"))?;
    if chars.characters.is_empty(){return Err("account has no characters".to_string());}
    let selected=match character_name{Some(w)=>chars.characters.iter().find(|c|c.name.eq_ignore_ascii_case(w)).ok_or_else(||format!("character not found: {w}"))?,None=>&chars.characters[0]};
    println!("[WORLD] portal login character={}",selected.name);
    CMSG_PLAYER_LOGIN{guid:selected.guid}.write_encrypted_client(&mut *stream,crypto.encrypter()).map_err(|e|format!("player login write: {e:?}"))?;
    let mut ready=false; for _ in 0..256 { let op=ServerOpcodeMessage::read_encrypted(&mut *stream,crypto.decrypter()).map_err(|e|format!("login verify: {e:?}"))?; if matches!(op,ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)){ready=true;break;} }
    if !ready{return Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD".to_string());}
    println!("[WORLD] portal WORLD READY"); portal_loop(stream,&mut crypto,soak_seconds)
}
