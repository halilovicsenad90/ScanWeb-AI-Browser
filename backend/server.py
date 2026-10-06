import os
import sqlite3
import traceback
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import litellm
import chromadb
from typing import Optional

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- BAZA ZNANJA (ChromaDB) ---
chroma_client = chromadb.PersistentClient(path="./knowledge_base")
knowledge_base = chroma_client.get_or_create_collection(name="handover_docs")

# --- HISTORIJA CHATA (SQLite) ---
def init_db():
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS chats
                 (session_id TEXT PRIMARY KEY,
                  title TEXT)''')
    c.execute('''CREATE TABLE IF NOT EXISTS messages
                 (id INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id TEXT,
                  role TEXT,
                  content TEXT)''')
    conn.commit()
    conn.close()

init_db()

def get_or_create_chat(session_id: str, title: str = "Novi Razgovor"):
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute("SELECT session_id FROM chats WHERE session_id = ?", (session_id,))
    if not c.fetchone():
        c.execute("INSERT INTO chats (session_id, title) VALUES (?, ?)", (session_id, title))
        conn.commit()
    conn.close()

def save_to_chat_history(session_id: str, role: str, content: str):
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute("INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)", (session_id, role, content))
    conn.commit()
    conn.close()

def get_recent_chat_history(session_id: str, limit: int = 8):
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute("SELECT role, content FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?", (session_id, limit))
    rows = c.fetchall()
    conn.close()
    messages = [{"role": row[0], "content": row[1]} for row in reversed(rows)]
    return messages

# --- RUTIRANJE ---
class MemorizeRequest(BaseModel):
    session_id: str
    text: str

@app.post("/memorize")
async def memorize_document(request: MemorizeRequest):
    try:
        chunks = [request.text[i:i+1000] for i in range(0, len(request.text), 1000)]
        ids = [f"doc_{request.session_id}_{i}_{os.urandom(4).hex()}" for i in range(len(chunks))]
        metadatas = [{"session_id": request.session_id} for _ in chunks]
        knowledge_base.add(documents=chunks, ids=ids, metadatas=metadatas)
        return {"status": "success", "message": f"Dokument je spremljen isključivo u bazu ovog chata."}
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

class ChatRequest(BaseModel):
    session_id: str
    message: str
    provider: str
    api_key: str
    model: str
    save_user_prompt: bool = True
    image_base64: Optional[str] = None
    max_tokens: int = 8000 
    is_debate: bool = False # NOVO: Zastavica koja nam govori da li je upaljen mod debate

@app.post("/chat")
async def process_chat(request: ChatRequest):
    try:
        get_or_create_chat(request.session_id)
        
        if request.save_user_prompt:
            save_to_chat_history(request.session_id, "user", request.message)

        relevant_knowledge = ""
        if knowledge_base.count() > 0 and len(request.message) > 15:
            results = knowledge_base.query(
                query_texts=[request.message], 
                n_results=2,
                where={"session_id": request.session_id}
            )
            if results['documents'] and results['documents'][0]:
                relevant_knowledge = "\n\n--- KONTEKST IZ BAZE ---\n" + "\n\n".join(results['documents'][0])

        # OSNOVNI PROMPT
        system_prompt = (
            "Ti si koristan i stručan AI asistent u grupnom chatu. "
            "Ako korisnik pita nešto vezano za projekat, iskoristi ovaj kontekst za tačan odgovor:\n"
            f"{relevant_knowledge}"
        )
        
        # NOVO: DODATAK ZA DEBATU (Strožija pravila glasanja)
        if request.is_debate:
            system_prompt += (
                "\n\n--- STROGA PRAVILA DEBATE (AI POROTA) ---\n"
                "1. Pročitaj zadnje rješenje. Ako vidiš grešku ili način za optimizaciju, napiši ispravljen kod.\n"
                "2. Ako je zadnje rješenje drugog agenta apsolutno savršeno, tvoj odgovor mora biti isključivo ova riječ: [SLAŽEM_SE]. Zatim kratko objasni zašto se slažeš.\n"
                "3. STROGA ZABRANA: ZABRANJENO ti je da koristiš riječ [KRAJ_DEBATE] ukoliko u prethodnim porukama chata ne vidiš da su BAREM DVA druga agenta prije tebe već napisala [SLAŽEM_SE]!\n"
                "4. ZATVARANJE: Tek kada u historiji jasno vidiš tuđa dva [SLAŽEM_SE], ti preuzimaš ulogu sudije, zaustavljaš debatu i tvoja poruka mora izgledati tačno ovako:\n"
                "[KRAJ_DEBATE]\n"
                "[KONAČNO_RJEŠENJE]\n"
                "(...ovdje ispisuješ cijeli, pročišćeni kod oko kojeg se većina složila)."
            )

        messages_with_context = [{"role": "system", "content": system_prompt}]
        
        # PAMETNI MEMORY AGENT (Ovo radi i tokom debate da spriječi pucanje)
        raw_history = get_recent_chat_history(request.session_id, limit=8)
        safe_char_limit = request.max_tokens * 3
        history_text = "\n".join([f"{msg['role']}: {msg['content']}" for msg in raw_history])
        
        processed_history = []
        
        if len(history_text) > safe_char_limit and len(raw_history) > 2:
            print(f"[{request.provider}] Pokrećem Memory Agenta (Historija prelazi {safe_char_limit} slova)!")
            old_messages = raw_history[:-2] 
            recent_messages = raw_history[-2:] 
            old_text = "\n".join([f"{msg['role']}: {msg['content']}" for msg in old_messages])
            
            summary_prompt = (
                "Ti si 'Memory Agent'. Tvoj zadatak je da pročitaš ovaj stari dio razgovora i napraviš DETALJAN SAŽETAK. "
                "OBAVEZNO zadrži sve važne tehničke detalje, imena funkcija, kod i ključnu logiku. "
                "Izbaci nebitno ćaskanje. Tvoj sažetak će služiti kao memorija drugom AI asistentu da nastavi rad.\n\n"
                f"STARI RAZGOVOR:\n{old_text}"
            )
            
            try:
                summary_response = litellm.completion(
                    model=request.model,
                    messages=[{"role": "system", "content": summary_prompt}],
                    api_key=request.api_key
                )
                summary = summary_response['choices'][0]['message']['content']
                processed_history.append({"role": "system", "content": f"--- SAŽETAK RANIJEG RAZGOVORA (Pamti ovo) ---\n{summary}"})
                processed_history.extend(recent_messages)
            except Exception as e:
                processed_history = recent_messages 
        else:
            processed_history = raw_history

        # --- FIX ZA GEMINI (Sprječava grešku "model turn not supported") ---
        if not request.save_user_prompt:
            processed_history.append({"role": "user", "content": request.message})
        # -------------------------------------------------------------------

        messages_with_context.extend(processed_history)

        if request.image_base64:
            for msg in reversed(messages_with_context):
                if msg["role"] == "user":
                    text_content = msg["content"]
                    msg["content"] = [
                        {"type": "text", "text": text_content},
                        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{request.image_base64}"}}
                    ]
                    break
        
        # GLAVNI ODGOVOR
        response = litellm.completion(model=request.model, messages=messages_with_context, api_key=request.api_key)
        ai_reply = response['choices'][0]['message']['content']
        formatted_reply = f"[{request.provider}]: {ai_reply}"
        
        save_to_chat_history(request.session_id, "assistant", formatted_reply)
        return {"status": "success", "reply": ai_reply}
        
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/chats")
async def get_chats():
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute("SELECT session_id, title FROM chats ORDER BY rowid DESC")
    rows = c.fetchall()
    conn.close()
    return {"chats": [{"session_id": row[0], "title": row[1]} for row in rows]}

@app.get("/history/{session_id}")
async def get_history(session_id: str):
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute("SELECT role, content FROM messages WHERE session_id = ? ORDER BY id ASC", (session_id,))
    rows = c.fetchall()
    conn.close()
    return {"messages": [{"role": row[0], "content": row[1]} for row in rows]}

class RenameRequest(BaseModel):
    title: str

@app.put("/chats/{session_id}")
async def rename_chat(session_id: str, request: RenameRequest):
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute("UPDATE chats SET title = ? WHERE session_id = ?", (request.title, session_id))
    conn.commit()
    conn.close()
    return {"status": "success"}

@app.delete("/chats/{session_id}")
async def delete_chat(session_id: str):
    conn = sqlite3.connect('chat_history.db')
    c = conn.cursor()
    c.execute("DELETE FROM chats WHERE session_id = ?", (session_id,))
    c.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))
    conn.commit()
    conn.close()
    try:
        knowledge_base.delete(where={"session_id": session_id})
    except:
        pass
    return {"status": "success"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)
