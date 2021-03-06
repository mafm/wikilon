
namespace Data.ByteString

module ByteStream =

    /// A ByteString Writer.
    ///
    /// This is similar to System.IO.MemoryStream in write mode, albeit
    /// with a simpler and more restrictive access limitations. Clients
    /// can capture only the data that they write to the stream. Older
    /// data cannot be observed or overwritten.
    ///
    /// Assumes single-threaded use. 
    ///
    /// The buffer is resized on write. A System.OutOfMemoryException
    /// is possible if the buffer cannot be resized sufficiently.
    type Dst =
        val mutable internal Data : byte[]  // resizable bytes array
        val mutable internal Pos : int      // current writer head
        internal new() = { Data = Array.empty; Pos = 0 }

    let inline private resize (sz:int) (d:Dst) : unit =
        assert(sz >= d.Pos)

    // reallocate array with sufficient space relative to Pos
    let private alloc (amt:int) (d:Dst) : unit =
        let maxAmt = System.Int32.MaxValue - d.Pos
        if (amt > maxAmt)
            then raise (new System.OutOfMemoryException("ByteStream reserve"))
        // adjust for geometric growth
        let newSize = d.Pos + max amt (min maxAmt (max 200 d.Pos))
        let mem = Array.zeroCreate newSize
        Array.blit (d.Data) 0 mem 0 (d.Pos)
        d.Data <- mem

    let inline private requireSpace (amt:int) (dst:Dst) : unit =
        let avail = dst.Data.Length - dst.Pos
        if (amt > avail) then alloc amt dst

    /// Reserve space for writing. 
    ///
    /// If this is the first operation on the stream, it performs an
    /// initial allocation of the exact size requested. Otherwise, it
    /// ensures there is space to write the amount requested without
    /// further reallocation.
    let reserve (amt:int) (dst:Dst) : unit =
        assert(amt > 0)
        if (Array.isEmpty dst.Data) 
            then dst.Data <- Array.zeroCreate amt
            else requireSpace amt dst

    let writeByte (b:byte) (dst:Dst) : unit = 
        requireSpace 1 dst
        dst.Data.[dst.Pos] <- b
        dst.Pos <- (1 + dst.Pos)

    let writeBytes (bs:ByteString) (dst:Dst) : unit =
        requireSpace (bs.Length) dst
        Array.blit (bs.UnsafeArray) (bs.Offset) (dst.Data) (dst.Pos) (bs.Length)
        dst.Pos <- (bs.Length + dst.Pos)

    let inline private captureBytes (p0:int) (dst:Dst) : ByteString =
        BS.unsafeCreate (dst.Data) p0 (dst.Pos - p0)

    /// Capture writes to a Dst.
    /// 
    /// This allows a client to observe whatever they have written
    /// without extra intermediate buffers or arrays. However, the
    /// initial Dst must be sourced at a `write` operation.
    let capture (dst:Dst) (writer:Dst -> unit) : ByteString =
        let p0 = dst.Pos
        writer dst
        captureBytes p0 dst

    /// Capture with an extra result.
    let capture' (dst:Dst) (writer:Dst -> 'X) : (ByteString * 'X) =
        let p0 = dst.Pos
        let x = writer dst
        let b = captureBytes p0 dst
        (b,x)

    /// Capture writes to a new stream. 
    ///
    /// Use of a `write` operation is the only means to construct the
    /// output stream, ensuring that all data is captured by at least
    /// one observer. You can use `reserve` immediately to provide an
    /// initial capacity.
    let write (writer:Dst -> unit) : ByteString = 
        capture (new Dst()) writer 

    /// Write with an extra result.
    let write' (writer: Dst -> 'X) : (ByteString * 'X) = 
        capture' (new Dst()) writer  

    /// A ByteString Reader. 
    ///
    /// This is similar to System.IO.MemoryStream in read-only mode, albeit
    /// without the ability to seek backwards and with alternative features
    /// for lookahead parsing. The motivation is to make it easier to reason
    /// about program behavior, and convenient integration with ByteString.
    ///
    /// Assumes single-threaded use.
    type Src =
        val internal Data : byte[]       // const
        val internal Limit : int         // max Pos
        val mutable internal Pos : int
        internal new(s:ByteString) =
            { Data = s.UnsafeArray 
              Limit = (s.Offset + s.Length) 
              Pos = s.Offset 
            }

    /// Generic exception for insufficient or unexpected data.
    exception ReadError

    /// End-of-Stream check.    
    let eos (src:Src) : bool = 
        (src.Limit = src.Pos)

    /// Check how many bytes remain in a stream.
    let bytesRem (src:Src) : int = 
        (src.Limit - src.Pos)

    /// Observe remaining bytes in stream without removing them.
    let peekRem (src:Src) : ByteString =
        BS.unsafeCreate (src.Data) (src.Pos) (bytesRem src)

    /// Read remaining bytes in stream. Removes them from stream.
    let readRem (src:Src) : ByteString =
        let result = peekRem src
        src.Pos <- src.Limit
        result

    /// Observe next byte in stream (or raise ReadError)
    let peekByte (src:Src) : byte =
        if eos src then raise ReadError else
        src.Data.[src.Pos]

    /// Read a single byte (or raise ReadError)
    let readByte (src:Src) : byte =
        let result = peekByte src
        src.Pos <- (1 + src.Pos)
        result

    /// Observe a run of remaining bytes without removing them.
    let peekBytes (len:int) (src:Src) : ByteString = 
        if(len < 0) then invalidArg "len" "negative byte count" else
        if(len > bytesRem src) then raise ReadError else
        BS.unsafeCreate (src.Data) (src.Pos) len

    /// Read run of bytes, removing them from the stream.
    let readBytes (len:int) (src:Src) : ByteString =
        let result = peekBytes len src
        src.Pos <- (len + src.Pos)
        result

    /// Ignore several bytes.
    let skip (len:int) (src:Src) : unit = 
        readBytes len src |> ignore<ByteString>

    /// Attempt to read a byte-stream, but backtrack on ReadError
    let tryRead (reader:Src -> 'X) (src:Src) : 'X option =
        let p0 = src.Pos
        try Some (reader src)
        with
        | ReadError -> src.Pos <- p0; None

    /// Attempt to read a byte-stream, but backtrack on ReadError or None.
    let tryMatch (reader:Src -> 'X option) (src:Src) : 'X option =
        let p0 = src.Pos
        try let result = reader src
            if Option.isNone result then src.Pos <- p0
            result
        with
        | ReadError -> src.Pos <- p0; None

    /// Read a ByteString.
    ///
    /// Note: This will raise a ReadError if we're NOT at the end-of-stream
    /// after performing a read. You might need to add a final readRem if 
    /// you aren't at the end of stream.
    let read (reader:Src -> 'X) (b:ByteString) : 'X =
        let src = new Src(b)
        let x = reader src
        if not (eos src) then raise ReadError
        x



type ByteSrc = ByteStream.Src
type ByteDst = ByteStream.Dst

