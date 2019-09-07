use miniserde::{json, Deserialize, Serialize};

pub enum MessageType {
    Helo,
    Request,
    Response,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct Message {
    msg_id: u32,
}

pub enum MessageError {
    InvalidType,
}

pub fn u32_to_msgtype(num: u32) -> Result<MessageType, MessageError> {
    match num {
        0 => Ok(MessageType::Helo),
        1 => Ok(MessageType::Request),
        2 => Ok(MessageType::Response),
        _ => Err(MessageError::InvalidType),
    }
}
