import Foundation

/// One plain-language fact about how this kind of AI works, shown at the top of
/// a new chat and gone once the first message is sent. A little literacy each
/// time, for people who never asked to learn the jargon.
nonisolated enum Facts {
    static let all: [String] = [
        "A language model does not look things up. It predicts the next word piece, over and over, from patterns it learned in training.",
        "The model on this phone is a table of about a billion numbers. Each reply is those numbers being multiplied together very quickly.",
        "A \"token\" is a piece of a word. \"Lantern\" might be one token; \"unbelievably\" might be three. Speed is measured in tokens per second.",
        "The model has no memory between chats. What it knows about this conversation is only what is on screen, fed back in each turn.",
        "\"4-bit\" means each number in the model is stored in four bits instead of sixteen. That is why a model that needs a server can fit in a phone.",
        "The same question gets different answers because the model rolls a weighted die for each word. Turning that off would make it repeat itself.",
        "The model only knows about the world up to the day its training text was collected. It cannot know today's weather, or today's news.",
        "Small models are confidently wrong more often than large ones. That is why the safety personas here answer from a written guide instead.",
        "Your phone's graphics chip does the model's arithmetic. It was built for games and photos, and it happens to be good at this too.",
        "Memory is the limit, not speed. The model's numbers plus its notes on the conversation have to fit in the memory iOS lets one app use.",
        "The first word of a reply takes longest. The model reads the whole conversation first, then writes one word at a time.",
        "Longer chats get slower. Each new word has to look back at every word before it.",
        "Nothing here uses the internet after the download. You can turn on airplane mode and nothing changes.",
        "A server answer runs on chips that draw hundreds of watts and need cooling. The chip in your hand draws a few watts and cools itself.",
        "\"Training\" is the months of computing that made the model. Using it, which is what happens here, is called inference and takes a fraction of a second.",
        "Models are made by companies and research groups and shared openly. The ones here come from Meta, Alibaba and Microsoft, converted for Apple chips by volunteers.",
        "MLX, the software running the model, was built by Apple's machine learning research team and is open source.",
        "A model with more numbers is not always smarter. Newer training data and better methods matter as much as size.",
        "The model cannot count reliably or do long arithmetic, because it was trained on text, not on a calculator.",
        "When the model \"forgets\" the start of a long chat, it is because its window filled up. Lantern summarises the older part so the gist stays.",
        "Every persona is just a paragraph of instructions the model reads before your message. You could write your own.",
        "The model has no sense of time passing. Ask it what time it is and it will guess.",
        "Models are best at language: rewriting, summarising, explaining, drafting. Treat facts from them as a lead, not an answer.",
        "The warmth you feel after a long session is the graphics chip working flat out. iOS slows it down before it gets too hot.",
        "\"Hallucination\" is the polite word for the model inventing something that sounds right. Smaller models do it more; asking for sources does not stop it.",
        "The weights on this phone were checked byte for byte against the publisher's checksum when they were downloaded.",
        "The model was trained mostly on English text, so it is better in English than in other languages, and better at common topics than rare ones.",
        "A one-billion-number model can write a reply in the time it takes a server request to travel to a data centre and back.",
    ]

    static func random() -> String {
        all.randomElement() ?? all[0]
    }
}
