# Nook 1.18.0

Fixed: meetings with coarse language could not be summarized at all.
Apple's model screens what it is asked to read, and raw profanity in a
transcript made it refuse before writing anything, which is why some
meetings summarized thinly or came back "declined".

- Nook now masks coarse words in the text it shows the model, using a
  fixed word list so nothing else can change: numbers, names, dates, and
  product words pass through exactly as spoken. Your stored transcript
  keeps every original word; only what the model reads is cleaned.
- The regeneration progress counter now labels its passes ("Pass 2,
  part 3 of 4"), because each pass re-chunks what remains and the
  shrinking totals used to read as broken arithmetic.
- Live captions in the meeting panel are left aligned, so the stream
  reads like a transcript instead of floating subtitles.
