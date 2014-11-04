
As an alternative to DSLs in Awelon project, I've developed a concept for 'embedded literal objects'. This concept gets some discussion on my blog [1](http://awelonblue.wordpress.com/2014/07/22/embedded-literal-objects/) and within the older Awelon project [2](https://github.com/dmbarbour/awelon/blob/master/doc/ExtensibleLiteralTypes.md). 

Essentially, the idea is to embed interactive but *isolated* applets within the source code, such that developers may interactively manipulate rich data structures, but the isolation allows these objects to easily be copied, shared, recorded within the AO dictionary and history, disentangled from one another. 

# Structure of ELO?

Roughly the following:

        µELO.[Query→Response | Update→ELO]
            where Update is in right    (0+U)
                  Query is in left      (Q+0)
        
        data ELO u q r = ELO 
            { query :: q → r
            , update :: u -> ELO u q r 
            }

        interface ELO {
            Val query(Val) const
            ELO update(Val) const
        }

If I had a precise notation for dependent types, this would be a fair bit easier. But the idea is that we're emulating an object with a set of query methods (which each return a result whose type may depend on the query) and a set of update methods (which return an updated ELO and nothing else) in a purely functional manner.

Queries might ask for menus of options, rendering in SVG or HTML, and other useful features for interacting with humans, in addition to domain specific queries or extractors. Meanwhile, the clean separation of updates from queries simplifies reasoning about consistent views between writers and readers. 

# Utilization of ELO within Wikilon Dictionary

I love this idea. But I'm having some difficulty with the original formulation.

The original design calls for embedding applets at the ABC level, then sharing code between objects as ABC resources. I might use `〚ABC〛` (U+301A-B) for the embedding. However:

1. I'd rather not deal with ABC resources as part of the AO dictionary. 
2. Transporting full applet code might be inefficient for a web service.
3. It isn't clear how multiple developers would interact with these ELOs.

I could embed ABC resources in the AO dictionary, but it would complicate the dictionary a fair bit. I'd rather avoid this complexity. I also have some intuitive objections that I cannot yet elucidate. A variation to working with `{#resourceId}` (secure hash, etc.) might be to use `{#word}`, perhaps warning if the word isn't frozen. But... I feel that if I'm to provide ad-hoc access to the AO dictionary, I should just stick with AO.

The transport costs for embedded literal objects could become significant, because embedded literals fill an important niche for representing large data structures (such as music, meshes, textures, documents). And for multiple developers, it could be very useful to merge operations on ELOs.

I have another idea, indirectly related to ELOs, for applications in the style of iPython notebook, xiki, spreadsheets, etc.. I can feasibly leverage AO naming conventions, e.g. words `c2$foo` and `b3$foo` defining cells in an implicit `$foo` spreadsheet. It seems entirely feasible that applications introspective/reflective on the AO dictionary could present useful, ad-hoc structures above simple naming conventions, and use these to guide views, rendering, updates. (In some senses, a dictionary represents a file-system, albeit with fine-grained structures and a high level of connectivity and computation.)

My thinking is that ELOs might be supported with a similar naming conventions. 

General thoughts:

* embedded object is word with name, type, static eval conventions
* types easily enforced by external policies, warnings or errors
* ELO words 'frozen'; update instead gives new word for new states
* command sequences on ELOs are preserved in dictionary by default
* occasional refactoring and checkpointing to shrink dictionary

So we might end up with something like this (distributed across transactions):

        @define o#1 blankCanvas 
        @define o#2 o#1 update1
        @define o#3 o#2 update2
        ...

Each word results in a new ELO word. The transport and storage costs, thusly, are limited to the expression of updates. We can still have the old 'copy+paste' benefits of literals, since we can trivially copy `o#3` into a new word, essentially forking the model. In the mid term, preservation of updates directly within the dictionary could be a significant advantage because it supports mining of this update history to find and refactor useful new words. 

The main weakness of this approach is the preservation of updates, which creates an unbounded storage cost if we make many changes to objects. But, as I mentioned earlier, this might be addressed by some combination of checkpointing and refactoring, guided by human agents or an expert system that can make good decisions about how much history to keep around. (An exponential decay model is also an interesting basis.)

Hmm. I think this approach is quite viable.

Another option is to aggregate updates ASAP, and factor more often...

        @define o#1 blankCanvas
        @update o#1 blankCanvas update1
        @update o#1 blankCanvas update1 update2
        @update o#1 blankCanvas update1 update2 update3

But this approach does complicate copy+paste. I think the earlier approach will be simpler and richer in the long run, i.e. shrinking the dictionary after the fact in a more ad-hoc and flexible fashion.

Anyhow, the important bit is that the resulting object can be evaluated statically, and is self-describing for rendering and further update options.

# Utilization of ELO in Wikilon Filesystem

It seems ELOs may be a pretty good fit as the basis for all stateful resources in Wikilon's [auxiliary state model](StateModels.md). In this case, the embedding is trivial! The objects are simply kept as plain old bytecode.

