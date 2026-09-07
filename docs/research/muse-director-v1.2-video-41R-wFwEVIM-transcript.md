# MiniMax H3 Director V1.2 update — full transcript

- Video: [MiniMax H3 Director - The Bugs Are FIXED 🔧 - V1.2 Update](https://youtu.be/41R-wFwEVIM)
- Channel: MuseCollective
- Video ID: `41R-wFwEVIM`
- Published: 2026-09-05
- Duration: 02:09:00
- Caption source: YouTube `en-orig` automatic captions
- Raw VTT SHA-256: `920997ee6a7fd1aa424abf22c50a348ad32b72480d597c451796b084589be184`
- Clean timestamped transcript SHA-256: `5909b83850754c06b43ee7afc341f43901cff1e77dc273e848ea349360a2eaca`

Automatic-caption errors are preserved. The clean transcript selects each stable caption cue, removes inline karaoke timing tags and consecutive exact duplicates, and retains source timestamps.

## Transcript

[00:00:48.229] Welcome to Muse Collective.
[00:00:51.510] Hello and welcome to Muse Collective.
[00:00:56.630] This is our update on the update. So,
[00:00:58.869] this past week or so, I've been working
[00:01:01.750] really hard to try and fix some of the
[00:01:05.910] bugs that were in the node um that are
[00:01:08.149] uh that were passed over in the comments
[00:01:10.789] from the YouTube the previous YouTube
[00:01:13.830] video. Um, and I think they're pretty
[00:01:17.350] much fixed. Um, if you've not seen the
[00:01:19.990] other videos, um, take a look at them if
[00:01:22.870] you wish, but this video is ridiculously
[00:01:25.749] long and probably explains it better.
[00:01:29.990] Um, okay. So,
[00:01:33.270] there's a few tweaks and bits and pieces
[00:01:36.310] going to come in this video. I apologize
[00:01:36.320] going to come in this video. I apologize because
[00:01:38.069] because
[00:01:40.230] the way I've recorded it is kind of back
[00:01:44.149] to front. Um, I did the fixes, recorded
[00:01:47.830] them as I did them, and this recording
[00:01:51.590] is the final recording once this node
[00:01:55.510] has been completed and updated. So, you
[00:01:57.510] may see or hear things slightly out of
[00:02:00.389] sequence. Um,
[00:02:02.310] and I may refer to things more than
[00:02:02.320] and I may refer to things more than once,
[00:02:03.910] once,
[00:02:06.389] but the good news is from all the
[00:02:09.990] testing, as far as I can see, we've
[00:02:12.550] fixed all the little niggly bugs that
[00:02:15.350] were in the comments, uh, or at least as
[00:02:19.270] much as possible. And now we have, uh, a
[00:02:22.470] really good node. It's working really
[00:02:24.309] well at the moment. and I'm going to run
[00:02:27.990] you through that in a second. Um,
[00:02:31.270] obviously the caveat is I can't tell you
[00:02:33.670] if this is going to work on your system
[00:02:37.030] at all. It may work, it may not work.
[00:02:37.040] at all. It may work, it may not work. It's
[00:02:39.190] It's
[00:02:41.270] these kind of nodes. They're always
[00:02:43.350] dependent on what you've already got
[00:02:46.070] installed and your system um
[00:02:46.080] installed and your system um capabilities.
[00:02:47.589] capabilities.
[00:02:50.630] On my system, it works really well. Um,
[00:02:53.830] at the moment I'm currently running a uh
[00:02:53.840] at the moment I'm currently running a uh RTX5090
[00:02:55.830] RTX5090
[00:02:55.840] RTX5090 and
[00:02:57.350] and
[00:03:00.869] I'm running it. I've only got 48 gig of
[00:03:04.790] RAM, system RAM. Um,
[00:03:07.110] and it works. I'm not going to say it's
[00:03:08.869] the fastest thing in the world because
[00:03:11.350] there's a lot of computational things
[00:03:13.509] within this node,
[00:03:16.229] but the results that you'll see later on
[00:03:18.710] in the video have all worked out and
[00:03:20.710] it's done really well.
[00:03:20.720] it's done really well. Um,
[00:03:23.270] Um,
[00:03:26.949] I'm going to run you briefly through
[00:03:29.110] this node
[00:03:32.470] or this workflow and then the rest of
[00:03:34.309] the video you should be able to pick out
[00:03:42.149] Okay. So
[00:03:45.430] over here we have got lots of notes
[00:03:49.350] about all the different uh nodes etc
[00:03:53.190] that are in this workflow. So you should
[00:03:55.750] be able to pick out from that and update
[00:03:57.990] as needed. There will be things in there
[00:04:01.030] that weren't in the last version. So if
[00:04:02.630] you're running the last version, my
[00:04:06.070] recommendation is delete it. download
[00:04:08.309] this one instead so you don't have any
[00:04:11.030] sort of conflicts.
[00:04:13.990] Um, this one has exactly what was in the
[00:04:17.270] other one and more. So, this this is the
[00:04:21.509] better version to use. Um, there are a
[00:04:24.469] few new
[00:04:27.030] models and nodes installed in this and
[00:04:28.629] I'll quickly run through that in a
[00:04:28.639] I'll quickly run through that in a second.
[00:04:30.310] second.
[00:04:30.320] second. Um,
[00:04:35.990] let's have a look.
[00:04:40.950] So over here, this is a new node that
[00:04:43.510] I've added. Now, you don't have to use
[00:04:47.110] this. Um,
[00:04:49.030] it was
[00:04:52.230] it was basically built to help VRAM
[00:04:55.670] quality, and it does to a degree. Um,
[00:04:57.749] it's it's not maybe something everybody
[00:05:00.390] wants to use. So it can be easily
[00:05:04.390] bypassed by just using
[00:05:06.469] the normal sort of system. So this is
[00:05:08.310] I've put all the models in a subgraph
[00:05:11.590] now. So if we open that up, you can see
[00:05:14.469] they've got the diffusion models, the
[00:05:18.070] clip VAE, and the Loras that I currently
[00:05:21.189] use and the attention models that I use.
[00:05:22.950] I've tried a few different attention
[00:05:24.629] models and I know everybody has a
[00:05:26.629] different opinion on this, but these are
[00:05:28.230] the ones that work well in this
[00:05:32.469] workflow. I've used solension. I've used
[00:05:35.590] um some of the other versions. And while
[00:05:35.600] um some of the other versions. And while they
[00:05:37.110] they
[00:05:40.710] do do things, I don't think the quality
[00:05:43.270] is there with them. And I'd rather wait
[00:05:46.070] a few minutes longer than have the
[00:05:49.350] quality not be as good. So, you can plug
[00:05:51.430] them in yourself. I've just these are
[00:05:54.150] the ones that I use in my workflow. So,
[00:05:55.749] literally, if you decide you want to
[00:06:00.310] plug in extra attention nodes, um all
[00:06:01.830] you got to do is just put them in the
[00:06:05.110] subgraph and link them in or just pull
[00:06:06.870] them from here, put them in on the
[00:06:09.990] canvas, drop the models into it, and out
[00:06:14.710] again into the node.
[00:06:14.720] again into the node. Um,
[00:06:17.670] Um,
[00:06:19.990] but basically
[00:06:21.510] I'll try and explain what this node
[00:06:24.550] does. So,
[00:06:28.469] for a start, it's part of a bigger
[00:06:31.510] project that I'm going to be working on.
[00:06:31.520] project that I'm going to be working on. Um,
[00:06:33.830] Um,
[00:06:35.670] and this kind of was the first step, but
[00:06:37.590] it works on its own independently, so I
[00:06:39.430] thought I'd use it in the workflow. So
[00:06:42.629] basically what it does is all your
[00:06:47.510] different clips, models, VAE, Loras,
[00:06:50.150] some of the attention models are all
[00:06:52.550] plugged into this one node. And you'll
[00:06:55.830] notice there's a lot. So
[00:06:58.870] it's created hopefully to help people
[00:07:04.629] with different um GPUs. So you download
[00:07:06.390] and again this is going to be space
[00:07:07.909] dependent. you may not have the kind of
[00:07:10.790] space to hold these different models,
[00:07:13.510] but we've got both the reference model
[00:07:15.189] and the first frame last frame model.
[00:07:18.150] And we have a Q4, a Q5, and a sort of
[00:07:22.629] full res uh version. Now, this node when
[00:07:25.830] it's set to automatic at the top here,
[00:07:29.110] it will read your computer in terms of
[00:07:31.589] what you've got and it outputs it here
[00:07:34.469] and it'll choose the correct
[00:07:38.469] um model for your system.
[00:07:38.479] um model for your system. Okay.
[00:07:39.990] Okay.
[00:07:41.830] So, mine, for example, when it's on
[00:07:44.469] automatic, mine gets maximum quality.
[00:07:47.589] You can see there it's got just under 32
[00:07:51.270] gig of VRAM. and it tells you um which
[00:07:52.950] models are loaded on there as well for
[00:07:56.790] that. And then that all outputs into the
[00:07:56.800] that. And then that all outputs into the node
[00:07:58.390] node
[00:08:07.189] these set nodes.
[00:08:07.199] these set nodes. Um
[00:08:14.150] as to whether it works, it does work. It
[00:08:17.830] does uh help with VRAM and I'll try and
[00:08:20.629] explain why.
[00:08:23.430] So basically the unifi loader it gives
[00:08:27.270] you real adaptive VRAM management. So it
[00:08:30.550] measures actual usage per shape tight
[00:08:33.589] tightens itself over repeat runs and
[00:08:36.230] sweeps leftover memory when things get
[00:08:39.190] tight. Um
[00:08:42.949] so it's not just a plain loader. So when
[00:08:44.550] you load a model through the unified
[00:08:47.430] loader it doesn't just load it and hope
[00:08:49.590] for the best. It roots through a system
[00:08:52.550] called H3 autoreserve
[00:08:54.630] which actually measures the real shape
[00:08:56.630] of what you're about to render, the
[00:08:58.310] resolution, the frame count, the batch
[00:09:01.509] size, etc. It works out how much of the
[00:09:04.150] model's weights need to stay resident in
[00:09:06.949] VRAM versus how much can safely stream
[00:09:09.829] from system memory. And it keeps a small
[00:09:11.750] safety buffer
[00:09:13.910] uh on top based on your card's own
[00:09:15.829] driver overhead.
[00:09:19.030] It's not a one-time guess either. Every
[00:09:22.070] time you render a given shape on the
[00:09:22.080] time you render a given shape on the GPU,
[00:09:24.710] GPU,
[00:09:27.030] it remembers the real measured result
[00:09:29.829] and tightens the number next time, so
[00:09:31.910] gets more accurate to your specific
[00:09:34.630] machine the more you use it. It also
[00:09:36.710] actively clears out anything left over
[00:09:38.870] from a previous run before committing to
[00:09:41.910] a new memory plan. So leftover vramm
[00:09:44.949] doesn't quietly stack up render after
[00:09:44.959] doesn't quietly stack up render after render.
[00:09:46.550] render.
[00:09:48.630] Um and a plain model loader just skips
[00:09:50.870] all that. It just uses comfy eyes
[00:09:53.990] generic one sizefits all estimate with
[00:09:57.110] no shape awareness. Um no tightening
[00:09:57.120] no shape awareness. Um no tightening etc.
[00:09:58.630] etc.
[00:10:02.310] So um which is why it tends to run much
[00:10:04.870] closer to the edge of your VR.
[00:10:09.670] So, it is a useful node. Um, but it's
[00:10:12.630] new, you know, potentially experimental.
[00:10:15.030] So, I'd encourage you to try it, see if
[00:10:17.509] it works for your machine, uh, and your
[00:10:20.069] VRAM. As I mentioned though, you would
[00:10:23.590] have to have the models loaded up so
[00:10:26.870] that obviously it can choose uh and you
[00:10:28.870] can either choose it to be automatic or
[00:10:31.990] you can go low VRM balanced or maximum
[00:10:34.470] quality which basically are the three
[00:10:37.670] different models.
[00:10:37.680] different models. Um
[00:10:39.910] Um
[00:10:43.190] yeah, and that's kind of that's kind of
[00:10:48.069] what that node does. Um, or as I said,
[00:10:50.389] failing that, just plug these into the
[00:10:54.069] node and you'll be fine. Be good to go.
[00:10:56.790] Um, that's the only real different thing
[00:10:58.790] that you're going to probably see on
[00:11:01.350] here. Um, as you can see, I'm running a
[00:11:05.350] render at the moment. Um, the
[00:11:07.590] actual UI itself has changed a little
[00:11:10.310] bit. Um,
[00:11:11.750] I'm not going to change it while mid
[00:11:14.150] run, but we've also got a hybrid mode
[00:11:18.150] now, which basically
[00:11:23.509] allows you to change models per chunk.
[00:11:27.509] So, you could have a, I don't know, a
[00:11:29.670] 30-cond video. The first chunk might be
[00:11:31.110] reference and the second one might be
[00:11:34.710] first frame, last frame. Um, and that
[00:11:37.030] works really well.
[00:11:40.069] Uh resolution wise
[00:11:42.550] pretty much the same same resolution as
[00:11:46.389] the last one resize method I have added
[00:11:49.990] an extra one called original. So in the
[00:11:53.190] node as it comes out of the box it's got
[00:11:57.030] crop pad and stretch. So original is
[00:11:59.190] basically just going to use whatever
[00:12:00.870] reference image you put in there rather
[00:12:04.550] than cropping it. Um
[00:12:09.350] these two it's you know this is basic
[00:12:12.150] these are basically about how it keeps
[00:12:16.629] continuity between chunks
[00:12:18.389] basically so that you get a seamless
[00:12:21.910] output. Um I would just leave them both
[00:12:23.750] on. They need really they should just
[00:12:27.509] stay on by default. Um to be fair I
[00:12:29.670] should probably just hide them. Uh
[00:12:31.910] little reference image size. I've been
[00:12:34.470] using Max most of the time now. Uh
[00:12:37.990] dialogue language speaks for itself.
[00:12:40.629] Sampling, I've been using uler and beta
[00:12:43.269] for pretty much all my runs.
[00:12:46.870] And the two-step sampling has changed
[00:12:50.310] slightly. We're now using the Minimax H3
[00:12:53.990] latent upscaler 3D.
[00:12:57.190] Um and
[00:12:59.990] back to this one. And in terms of luras,
[00:13:04.150] I'm using the eightstep lura. And this
[00:13:06.389] one has seemed to be pretty good. It's
[00:13:09.910] it's done really well in this. Um,
[00:13:12.389] so I've got it generally I've had it set
[00:13:15.269] at eight steps.
[00:13:15.279] at eight steps. And
[00:13:17.110] And
[00:13:19.590] when you come down to the upscaler,
[00:13:21.430] basically all you're doing is put in the
[00:13:23.590] first steps and then it'll automatically
[00:13:26.389] calculate what's remaining. So, I've
[00:13:28.710] been doing a four step first pass and a
[00:13:31.670] four step second pass. I've also been
[00:13:35.110] doing 10 steps. So, if you've got the
[00:13:37.269] time and you want to do it that way, I
[00:13:40.069] found doing 10 steps with six steps
[00:13:42.069] first pass has worked really well as
[00:13:46.230] well. Um, I haven't tried it past 1
[00:13:49.350] megapixel yet. Uh, that's on the to-do
[00:13:58.230] also as well actually with this
[00:14:00.629] particular upscaler, it's got temporal
[00:14:04.230] chunking. I've turned this off. Um I
[00:14:06.389] found I don't think speeds anything up
[00:14:08.949] particularly, but I found it works
[00:14:11.189] better for me.
[00:14:14.230] The other buttons on here, um I think I
[00:14:16.629] go through these later in the video. Uh
[00:14:18.550] seed hunt, that's still there. So, we've
[00:14:18.560] seed hunt, that's still there. So, we've got
[00:14:20.389] got
[00:14:23.829] the four seed hunt boxes
[00:14:26.470] and now
[00:14:28.550] there was a bug before and I think that
[00:14:30.230] does get explained later on. So, that's
[00:14:32.230] been fixed. But now we've got enable
[00:14:35.750] seed hunt and we've got um latent only
[00:14:39.269] scouting. So, those two get uh switched
[00:14:40.790] on when you're doing the seed hunt
[00:14:43.829] version. And instead of the way it was
[00:14:46.870] before, you choose from here how many of
[00:14:49.350] those you want to do. So before it
[00:14:51.910] defaulted to one, but now um you've got
[00:14:53.590] the option of one. I mean it makes no
[00:14:55.590] difference. I mean one seed hunt is just
[00:14:58.870] the same as doing a nonse. Um but yeah,
[00:15:01.509] so you've got one, two, three, or four.
[00:15:03.670] And one of the bugs I think it was doing
[00:15:06.150] before was if you were to type four, it
[00:15:08.230] would just do number one and number four
[00:15:10.470] and miss number two and three. So,
[00:15:14.069] that's been fixed. Um,
[00:15:15.910] other than that, in the node itself,
[00:15:18.389] it's had a slight redesign. Nothing
[00:15:21.670] major. Um,
[00:15:23.269] you can now delete chunks. I can't
[00:15:24.629] remember if I had that on the last one.
[00:15:28.230] I think I might have done. And you can
[00:15:29.990] type in
[00:15:31.829] the seconds here instead of just
[00:15:34.310] dragging it.
[00:15:34.320] dragging it. And
[00:15:35.829] And
[00:15:38.310] references. I've just tidied this up a
[00:15:39.829] little bit.
[00:15:39.839] little bit. So,
[00:15:46.150] okay. So, I've done what I've done is
[00:15:48.150] one of the things the last node had, it
[00:15:50.069] had nine reference boxes, which was
[00:15:54.069] misleading because the location box is
[00:15:56.710] technically one of the nine references.
[00:15:59.189] So, if you were to put a location image
[00:16:02.230] in and you then you tried to fill up all
[00:16:03.910] nine of the other boxes, one of them
[00:16:06.870] would just get dropped. So, I've changed
[00:16:09.990] that so that there's eight. Um, and then
[00:16:13.910] the location becomes the ninth one
[00:16:16.550] basically. Um, there's a lot of things
[00:16:19.350] on the reference video that I've changed
[00:16:21.030] and I've changed some of the audio
[00:16:22.710] stuff, but look through the rest of the
[00:16:25.110] video to find that.
[00:16:27.749] Other than that, it's I think that Oh,
[00:16:29.350] there's one other thing I've done here
[00:16:31.829] actually. So, the refined node needed
[00:16:34.949] changing as well to match the upscaler.
[00:16:34.959] changing as well to match the upscaler. Um,
[00:16:36.470] Um,
[00:16:38.069] and a couple of little bugs that were in
[00:16:40.710] there got fixed as well. And I've got
[00:16:42.629] rid of some of the options because they
[00:16:45.350] weren't needed. Um, really it needs to
[00:16:50.949] match the the main sort of model.
[00:16:55.829] Uh, yeah. Okay.
[00:16:55.839] Uh, yeah. Okay. So,
[00:16:57.670] So,
[00:17:00.710] not that you can really see it. But up
[00:17:03.430] here, I know as well this node seems to
[00:17:05.429] have like taken over the whole canvas.
[00:17:07.350] Yeah, I get that. It's it's a bit of a
[00:17:09.110] big node. It's dwarfs all the other
[00:17:11.110] things. But when you zoom in on this
[00:17:15.590] one, I've put a run counter as well. So,
[00:17:19.189] what it kind of does is obviously a run
[00:17:20.789] counter. It tells you how long that last
[00:17:24.870] run I just did was 24 minutes. Um, and
[00:17:27.669] I've I've had it output the average
[00:17:30.789] stats. So, average GPU,
[00:17:34.549] um, VRAMm and RAM just for your own
[00:17:36.310] reference really. I just wanted to know
[00:17:39.350] overall per run, what was it averaging?
[00:17:43.830] Um, and clearly there 18 uh gigabytes
[00:17:46.390] out of 31.
[00:17:46.400] out of 31. Um,
[00:17:48.470] Um,
[00:17:50.549] that's kind of it. These bits here are
[00:17:52.310] explained later on. They're all to do
[00:17:55.510] with the um
[00:18:02.470] Yeah, I think that's kind of everything
[00:18:04.630] to be fair.
[00:18:06.789] All right, so I encourage you to go
[00:18:08.870] through the rest of the video and I
[00:18:12.549] really apologize. It's uh it's long.
[00:18:14.470] It's really long. I didn't intend it to
[00:18:15.909] be. I thought it would be a quick sort
[00:18:18.710] of update video, but the thing with
[00:18:20.870] updating it really, I feel like I had to
[00:18:20.880] updating it really, I feel like I had to prove
[00:18:22.470] prove
[00:18:24.789] each one working as we did it. So,
[00:18:27.750] there's a lot of renders and a lot of uh
[00:18:31.830] videos to sort of look through.
[00:18:34.710] Um, if you have any questions, obviously
[00:18:38.390] pop them in the comments. I If you like
[00:18:40.549] what you see, really encourage you to
[00:18:43.590] subscribe. This is a new channel for me.
[00:18:45.750] It's a new new thing that I'm kind of
[00:18:48.150] trying to try and obviously the more
[00:18:51.110] subscribers I get the better and you
[00:18:53.190] know it'll benefit everybody in the long
[00:18:55.990] run if I can stay on the channel and
[00:18:59.510] create more of these things.
[00:19:01.590] As I said, this node might not be for
[00:19:03.510] everybody. Some people will like it,
[00:19:04.950] some people won't, and that's fine.
[00:19:06.230] Everybody's got their own personal
[00:19:09.990] taste. Um, there are other different uh
[00:19:11.990] versions of director nodes out there
[00:19:13.830] which probably do some things a lot
[00:19:17.350] better than this. Um, but with this one
[00:19:20.549] I'm particularly happy with and a lot of
[00:19:22.630] these features
[00:19:24.470] and more are going to be in the version
[00:19:25.909] two which I'm still in the middle of
[00:19:27.669] working on and had to put on pause while
[00:19:31.990] we did this. Um, okay. So that's pretty
[00:19:33.669] much it for the introduction. The one
[00:19:35.590] last thing I'm going to do before I do
[00:19:39.350] anything else once um
[00:19:41.430] once I've finished uploading it to
[00:19:45.750] GitHub, I'm going to do a complete run
[00:19:47.750] of this. I'm going to I've got another
[00:19:50.310] version of Comfy UI with nothing on it.
[00:19:52.310] So, it's a blank slate. I'll be
[00:19:54.470] downloading it and I'll do a video of
[00:19:54.480] downloading it and I'll do a video of actually
[00:19:56.070] actually
[00:19:57.990] downloading and unpackaging the whole
[00:20:01.510] thing just so that we know that it works
[00:20:04.470] straight out of the box. Okay, I'll see
[00:20:06.549] you in the next bit.
[00:20:10.150] Okay, so I'm going to do a fresh install
[00:20:13.110] of this node to test it out, make sure
[00:20:15.350] it's doing what it should. So this is a
[00:20:19.510] fresh instance of comfy UI. Um,
[00:20:22.710] nothing's installed on this yet at all.
[00:20:24.710] No workflows except for the ones that
[00:20:28.870] come with it. And I'm going to get clone
[00:20:32.149] the repository, open it up, and
[00:20:35.430] hopefully we should be good to go. So
[00:20:39.590] bear with me while I get clone.
[00:20:43.669] Okay, so here we go. So go into comfy
[00:20:46.630] custom nodes
[00:20:46.640] custom nodes cmd
[00:20:56.549] get clone.
[00:20:59.750] Paste in a link.
[00:20:59.760] Paste in a link. Done.
[00:21:01.270] Done.
[00:21:08.230] And first thing we need, we also need
[00:21:11.750] the workflow. So could download that
[00:21:14.470] from git clone too.
[00:21:17.190] Sorry, GitHub, not git clone. And we'll
[00:21:19.830] drag and drop that in.
[00:21:22.470] There we go. So as expected, we have got
[00:21:32.470] And let's have a look.
[00:21:40.870] Let's have those. You may already have
[00:21:43.430] these ones. As I said, this is a a fresh
[00:21:43.440] these ones. As I said, this is a a fresh install.
[00:22:00.070] Okay. So, that is done.
[00:22:02.630] Let's have a look. So, we have a couple
[00:22:06.070] of errors. Let's have a look at these.
[00:22:08.950] Those ones there.
[00:22:11.750] B details
[00:22:23.270] So,
[00:22:26.070] so we've got some missing models, which
[00:22:28.630] is understandable because they won't be
[00:22:30.950] in here anywhere.
[00:22:39.510] Yeah. Okay. So, we still we need to do
[00:22:43.110] the run stats and the unified loader. Uh
[00:22:47.029] those are in separate repos.
[00:22:49.990] I'm going to add all these to the
[00:22:53.029] comments. Not the comments, the notes
[00:22:53.039] comments. Not the comments, the notes below.
[00:23:03.029] So, I already have that. So, I'm going
[00:23:08.310] to copy it over. Right, bear with me.
[00:23:11.430] Okay, so
[00:23:13.750] unified loader.
[00:23:25.029] That's that one.
[00:23:29.590] And the other one is the run stats node.
[00:23:31.029] This one is an essential. If you don't
[00:23:32.390] want to use it, just delete it from the
[00:23:32.400] want to use it, just delete it from the workflow.
[00:23:47.270] done.
[00:23:50.630] Okay, so those two are in. Let's restart
[00:23:53.270] CompuI again.
[00:24:01.669] I'll restart again once it's connected.
[00:24:03.750] Okay, that's done.
[00:24:15.510] Okay, so they've loaded, but we have a
[00:24:17.029] problem. So, let's find out what that
[00:24:17.039] problem. So, let's find out what that is.
[00:24:24.310] Okay, so obviously there's all the
[00:24:33.029] Right. Okay, bear with me.
[00:24:36.870] Okay. So, on your own install,
[00:24:39.029] just use the links here to install the
[00:24:45.510] and add them to the correct folders.
[00:24:47.590] Obviously, make sure that your Comfy UI
[00:24:50.710] is the latest up to-ate version as well.
[00:24:52.710] Mine obviously is cuz I've just
[00:24:55.029] installed it, but make sure yours is
[00:24:57.750] completely up to date before you try and
[00:25:00.310] install or run the node.
[00:25:04.070] Uh, okay. So, mine should be okay to go.
[00:25:11.669] and then I'll get back to you once
[00:25:13.590] that's restarted.
[00:25:16.470] Okay, that's good to go. Let's give it a
[00:25:16.480] Okay, that's good to go. Let's give it a refresh.
[00:25:28.149] Okay, so we've got nothing missing
[00:25:37.750] Yeah, all the models are now inserted
[00:25:37.760] Yeah, all the models are now inserted in.
[00:25:39.830] in.
[00:25:42.710] And I don't see any actual problems
[00:25:42.720] And I don't see any actual problems there.
[00:25:48.549] Yes.
[00:25:51.190] And this node, this is the refine node,
[00:25:55.830] which yeah, was bundled up with
[00:25:57.990] the director node. Right, I'm going to
[00:26:00.310] do one quick test and then I think this
[00:26:03.110] is good to go. Um, so I'm just going to
[00:26:03.120] is good to go. Um, so I'm just going to use
[00:26:05.510] use
[00:26:12.149] timelines.
[00:26:20.230] And we're just going to use the alert
[00:26:33.029] Let's get an image for that one.
[00:26:40.950] Okay. So, we're just analyzing that. So,
[00:26:42.470] we get a description, which is
[00:26:42.480] we get a description, which is important.
[00:26:45.110] important.
[00:26:48.870] And we're just going to do one chunk to
[00:26:51.510] check it all out.
[00:26:53.590] And what we're on reference mode, 15
[00:26:53.600] And what we're on reference mode, 15 seconds,
[00:26:55.190] seconds,
[00:26:55.200] seconds, 0.5,
[00:27:01.190] all ticked. These need to be ticked.
[00:27:06.390] We're going to be on and 10 steps
[00:27:09.510] and two stage sampling. Okay, so that's
[00:27:10.789] good to go.
[00:27:12.710] I'm just going to do it as a regular one
[00:27:14.870] or seed hunt.
[00:27:24.870] Okay, we've got an error. Right, bear
[00:27:27.990] with me.
[00:27:30.310] Okay, so this error is because I didn't
[00:27:33.029] read the notes,
[00:27:37.510] ironically. So, we've got a red box
[00:27:41.029] and it is not in there.
[00:27:48.470] it is just one of the dependencies
[00:27:51.350] that's needed in that loader
[00:27:51.360] that's needed in that loader and
[00:27:52.950] and
[00:28:15.990] There it is.
[00:28:16.000] There it is. So,
[00:28:17.909] So,
[00:28:24.149] basically the one that's missing is um
[00:28:26.389] where's it gone?
[00:28:29.590] The multi-shot one. So, yeah. So, this
[00:28:33.350] first one needs to be loaded. uh in. So,
[00:28:34.950] you just need to make sure you click it,
[00:28:47.190] Literally, if you just click on the the
[00:28:50.630] text, it'll open the GitHub repo for you
[00:28:53.510] and just get clone that one.
[00:28:59.669] that should be the last one. So, let's
[00:29:07.430] so back on there again.
[00:29:10.630] Copy that
[00:29:23.750] Okay, so we're back in custom nodes.
[00:29:23.760] Okay, so we're back in custom nodes. CMD
[00:29:33.750] Done.
[00:29:37.590] Okay, hopefully one more restart.
[00:29:45.510] Okay, that's done as well.
[00:29:45.520] Okay, that's done as well. Reload.
[00:29:56.630] And everything else still set. Red box
[00:30:06.789] And it looks like we're good to go
[00:30:14.389] Okay, my bad. So, there's still a couple
[00:30:17.190] of things that need installing.
[00:30:21.029] Um, one of them is the motion context
[00:30:21.039] Um, one of them is the motion context multire
[00:30:23.590] multire
[00:30:23.600] multire and
[00:30:47.190] Okay, that's that one. And there is one
[00:31:05.190] And lastly, the late upscaler. So, still
[00:31:08.470] got that there. So,
[00:31:13.909] Done.
[00:31:20.950] This is the difference when you're
[00:31:23.269] actually designing the node. You kind of
[00:31:24.870] plug them in as you go. You don't have
[00:32:24.310] Yeah, here we go. Obviously, it's a
[00:32:26.630] first run, so it's going to needs to
[00:32:47.509] and there we go. It's starting to
[00:32:47.519] and there we go. It's starting to generate
[00:32:54.950] and I will get back to you once this is
[00:32:54.960] and I will get back to you once this is finished.
[00:32:57.029] finished.
[00:33:27.830] Okay, so that's the installation. So the
[00:33:31.430] main thing that I clearly forgot is go
[00:33:34.389] through these. Make sure you install all
[00:33:36.870] the nodes first.
[00:33:36.880] the nodes first. Um
[00:33:39.430] Um
[00:33:41.350] I did actually put a download these
[00:33:43.590] first node.
[00:33:46.070] If you find there's something missing,
[00:33:48.310] there shouldn't be. I went through all
[00:33:51.669] these with Claude and
[00:33:54.230] yeah, he's pretty good.
[00:33:56.870] If it doesn't, it will just error out.
[00:33:59.350] Copy the error, give it to Claudo chat
[00:34:00.789] GPT, and it'll tell you which one's
[00:34:04.310] missing. Simple. Simple. Um, other than
[00:34:04.320] missing. Simple. Simple. Um, other than that,
[00:34:06.230] that,
[00:34:06.240] that, the
[00:34:08.069] the
[00:34:10.069] rest of the workflow, um, sorry, the
[00:34:13.510] rest of the video is ridiculously long,
[00:34:15.030] and I've probably said that a couple of
[00:34:18.069] times already. I apologize, but I want
[00:34:21.510] to give as much detail as I can. So, uh,
[00:34:23.829] work through it. do it in chunks if you
[00:34:28.149] wish. Um, but it should give. Okay. So,
[00:34:31.430] one of the changes that I've made to the
[00:34:33.909] version 1.2
[00:34:33.919] version 1.2 is
[00:34:35.669] is
[00:34:38.950] um in the reference audio. So, someone
[00:34:41.589] me messaged um saying it'd be better if
[00:34:44.470] you could type in the setting set out,
[00:34:46.149] which we've done. So, you can now just
[00:34:48.790] click on it, type in when you want the
[00:34:50.629] setting from the reference audio and the
[00:34:54.629] set out. Um, so this is handy if you've
[00:34:57.750] got a really long reference clip because
[00:35:01.270] you don't need to have like an 80 second
[00:35:04.310] clip for reference uh reference for
[00:35:06.390] cloning your voice. 25 seconds is
[00:35:09.990] perfectly fine. Um, I think this audio
[00:35:13.430] clip is like 88 seconds long. So, we've
[00:35:15.430] set it to 25, so it doesn't need too
[00:35:18.790] long. Um, also as well for lip syncing
[00:35:21.829] it can work really well because you can
[00:35:24.390] set your inpoint and your outpoint. So
[00:35:26.870] if you want to do it in chunks,
[00:35:30.230] you can set an inpoint at zero, an
[00:35:33.589] outpoint at 10, then do a second run
[00:35:36.069] with the set in at 10, and the set out
[00:35:38.710] at 20. So effectively doing 10 seconds
[00:35:45.030] and we're going to do someone else
[00:35:47.190] mentioned in the comments as well about
[00:35:49.109] voice cloning and it not working
[00:35:51.990] properly. So, I've already done the test
[00:35:53.829] on this and adjusted what needs
[00:35:57.030] adjusting. So, I'll show you the output.
[00:35:59.030] But basically, you can see in the drop
[00:36:00.390] down, those are the different things we
[00:36:04.310] have. So, voice reference is for voice
[00:36:06.710] cloning. Basically, lip sync is slightly
[00:36:09.430] different because you're using the audio
[00:36:13.109] file to drive the video. Um, and then
[00:36:15.109] we've got partial voice match and weak
[00:36:17.270] voice match. So, it's just a couple of
[00:36:20.870] different uh choices there. Uh, I've
[00:36:24.470] tidied up this bit as well,
[00:36:26.870] just while we're down this end. So,
[00:36:29.430] someone else mentioned about using
[00:36:33.030] multiple images as location.
[00:36:36.630] So, we've got the normal location box
[00:36:36.640] So, we've got the normal location box which
[00:36:38.310] which
[00:36:40.870] uh is used per chunk.
[00:36:42.470] But say for example, you want a
[00:36:45.510] different location in chunk 2.
[00:36:49.670] So now you can add one here.
[00:36:52.390] It adds another box and you can put
[00:36:54.870] which chunk it's from. So the first one
[00:36:57.270] will be chunk one by default. So if you
[00:36:59.670] want it to go into chunk two, you've got
[00:37:02.069] it in chunk two there. You can add a
[00:37:04.310] third one for chunk three, etc. I've
[00:37:06.550] only done it up to seven. I'm not sure
[00:37:09.270] people will use more than that, but this
[00:37:11.910] way you can change the location. So,
[00:37:13.829] even if it's the same room from a
[00:37:15.990] different angle, for example, you might
[00:37:18.550] want to have your character move into
[00:37:20.630] that area. So, this should help with
[00:37:24.790] that. Um,
[00:37:26.870] but that again, it's experimental. You
[00:37:28.630] might have to shop and change it a
[00:37:31.030] little bit. Uh, and you can delete those
[00:37:33.270] ones there as well.
[00:37:39.829] We're probably, although the node has
[00:37:43.190] nine reference images
[00:37:47.030] on here, we've only got seven and that
[00:37:49.670] might be eight shortly. The location one
[00:37:53.030] acts as one of those references. So on
[00:37:54.710] the first version that you'll you'll
[00:37:57.750] have had it'll said nine reference boxes
[00:38:00.470] which was a mistake because it's not
[00:38:02.790] nine reference images plus a location
[00:38:06.069] image. Your location image takes up one
[00:38:10.950] of those reference images. So initially
[00:38:13.349] there was also one image being used for
[00:38:15.910] the carry on from one chunk to the next
[00:38:19.829] which we've now changed. So, this should
[00:38:22.550] change back to eight, which is what
[00:38:25.670] we'll probably do next to that. Uh, hope
[00:38:28.150] that makes some sort of sense.
[00:38:28.160] that makes some sort of sense. And
[00:38:31.030] And
[00:38:34.230] okay, so let's just do the cloning bit
[00:38:37.349] first. So, I've done three chunks. So,
[00:38:39.670] this is a 45 second video. Again, just
[00:38:41.589] to sort of show the continuity between
[00:38:45.030] chunks. Um,
[00:38:46.710] it's a prompt that I've used on other
[00:38:50.310] things. Uh it's just like a I don't know
[00:38:52.630] a control room and an alert and things
[00:38:52.640] a control room and an alert and things happening.
[00:38:54.230] happening.
[00:38:57.349] Uh at the top well at the top I'm going
[00:38:59.109] to go through some of the little bits
[00:39:01.829] and pieces. Um
[00:39:06.069] but the actual
[00:39:10.150] cloning of the voice is here.
[00:39:12.630] Now I'm not going to put So this is my
[00:39:16.230] image basically. So, we've got
[00:39:19.589] So, we've got my image here
[00:39:22.150] as the reference and the actual audio
[00:39:25.030] that I put in is is my voice.
[00:39:28.310] Um, and I'll tag this video on at the
[00:39:31.829] end of this little bit, but this is
[00:39:36.710] the video. Gosh. Um,
[00:39:38.710] and it's got my voice basically. So,
[00:39:40.150] I'll tag this on so you should be able
[00:39:42.870] to see that. Uh, and then I'm going to
[00:39:46.230] move on to the next part of the of what
[00:40:28.069] And this is what voice cloning sounds
[00:40:31.349] like with Miniax H3. The voice you're
[00:40:35.109] hearing genuinely is my voice.
[00:40:37.270] Okay. So, one of the other things that
[00:40:41.030] was people were concerned with was the
[00:40:41.040] was people were concerned with was the um
[00:40:42.790] um
[00:40:45.750] seat hunt. So, I've had a look at that
[00:40:51.829] and I've also changed that slightly. Um
[00:40:54.230] there was a slight bug in it. So, rather
[00:40:56.550] than try and explain everything, I just
[00:40:59.030] admit there was a bug there and it's now
[00:41:01.109] fixed. So, I'm going to do a run so you
[00:41:04.150] can see. Um,
[00:41:07.270] so we're going to enable seed seed hunt.
[00:41:09.190] Basically, what was happening before was
[00:41:12.470] you could choose how many candidates to
[00:41:16.790] seed hunt or seed scout. The problem was
[00:41:18.950] what it was doing. You could choose one,
[00:41:20.470] two, three, or four. Sorry, you could
[00:41:22.870] choose two, three, or four. And one was
[00:41:25.670] always going to output as a default. The
[00:41:28.950] problem was that it was choosing one. If
[00:41:31.030] you chose four, it would choose one and
[00:41:33.430] four, not all four. So that's been
[00:41:37.030] resolved now. So candidates to scout,
[00:41:38.470] one, two, three, or four. So we're going
[00:41:41.430] to do four. So it should output four
[00:41:45.190] different uh seed scouts. Make sure that
[00:41:47.829] latent scout is on.
[00:41:50.309] And we don't need that bit. These are
[00:41:53.190] all fine. Um
[00:41:55.109] I'll go through this bit again, but I've
[00:41:58.230] also changed the two-stage sampling.
[00:42:00.950] So, we're not using the method we used
[00:42:03.829] on the previous one, which had three
[00:42:06.150] steps at the beginning, and it was a bit
[00:42:09.190] muddier on the actual seeds, the seed
[00:42:11.270] scout element, because it was only
[00:42:14.069] outputting the third first three steps.
[00:42:16.309] We're now using the minimax latent
[00:42:21.510] upscalia three upscaler 3D. Um, and this
[00:42:27.270] I found is way better. Um so
[00:42:30.470] it basically
[00:42:34.230] if you're in single uh single
[00:42:34.240] if you're in single uh single step
[00:42:35.750] step
[00:42:37.349] sampling sorry if you're in single
[00:42:40.150] sampling one stage sampling then you put
[00:42:43.270] your target resolution here. So that's
[00:42:45.510] one megapixel
[00:42:49.829] um and that's what it will upscale to.
[00:42:51.990] So we've got over here we've got
[00:42:55.430] megapixels 0.4. So, if it was in single
[00:42:57.750] stage sampler, it would just do a 0.4
[00:42:59.990] megapixel video.
[00:43:02.630] In two-stage sampling, it's going to do
[00:43:07.030] the four the first four steps and then
[00:43:10.230] it's going to use the target megapixels
[00:43:13.109] to upscale two. Now, I've not tested it
[00:43:17.670] past one, but um on the documents and
[00:43:19.750] the video that I saw this on, someone
[00:43:21.829] did do it up to two. I've not tested
[00:43:24.069] that yet and I'm not sure I want to test
[00:43:28.790] it on seed hunt, but it works way better
[00:43:32.710] than the other version. So
[00:43:34.950] for seed hunt, just leave it as this
[00:43:36.790] here. But it's not essential that you do
[00:43:40.069] it here because we've also created a
[00:43:40.079] it here because we've also created a new,
[00:43:41.910] new,
[00:43:45.270] let me unbypass this a minute,
[00:43:49.190] a version two refine node. So this will
[00:43:52.950] use the upscaler too and it will upscale
[00:43:56.470] the final part of the image.
[00:43:57.990] So we'll show I'll show you this in
[00:44:01.510] practice now. But just so you're aware
[00:44:04.630] the two scale the two-stage upscaling
[00:44:06.950] has changed.
[00:44:08.550] Everything else is right here for seed
[00:44:11.829] hunt with the prompt is a prompts we've
[00:44:15.510] used before. I've changed the character.
[00:44:15.520] used before. I've changed the character. Uh,
[00:44:26.150] okay. So, I've run it once and there was
[00:44:28.069] a little something I needed to change.
[00:44:32.230] So, it's running again now. Um,
[00:44:34.870] so we've changed the
[00:44:36.790] minimax refine node. So, we had to
[00:44:39.589] change it so that it um worked with the
[00:44:41.670] new upscaler.
[00:44:41.680] new upscaler. So,
[00:44:43.430] So,
[00:44:45.190] this one looks slightly different and
[00:44:47.670] it's just paired back. Basically, it
[00:44:50.390] works pretty much the same way. It takes
[00:44:53.349] the latent from the candidate that
[00:44:57.190] you've chosen and refineses that one by
[00:44:59.510] basically setting it putting it through
[00:45:02.390] the second stage sampler. Um, and
[00:45:04.790] continuing where the first stage sampler
[00:45:06.630] left off.
[00:45:09.910] Um, okay. And also within it, I've taken
[00:45:13.349] out the seed element to this. So you
[00:45:16.309] can't change it. Um, partly because it
[00:45:19.910] was confusing things. So
[00:45:21.910] on the previous version, you could
[00:45:24.630] change the seed um and have it as random
[00:45:26.870] or fixed whatnot.
[00:45:30.630] But that can influence the second stage
[00:45:34.870] sampler and also the scene joins uh when
[00:45:36.630] you're using multiple chunks. So that's
[00:45:39.190] been removed. What now happens is the
[00:45:42.950] latent itself carries the correct seed
[00:45:48.309] number and it uses that latent to uses
[00:45:50.550] the seed that's attached to that latent
[00:45:54.710] to do the second stage. So
[00:45:56.309] let's have a look at where we're up to
[00:46:05.589] Okay.
[00:46:09.430] So, we've got four candidates
[00:46:13.270] and let's just sync them.
[00:46:22.069] And
[00:46:24.309] yeah, so there's obviously this this is
[00:46:26.630] where you choose which one you think
[00:46:28.550] works better for you. So, I'm not going
[00:46:30.630] to use three
[00:46:33.109] or which is in fact two actually because
[00:46:35.349] she just sort of did a reverse on
[00:46:35.359] she just sort of did a reverse on herself.
[00:46:37.030] herself.
[00:46:38.710] Uh, what we're going to do is we're just
[00:46:48.630] Okay. And it's the same as before. So,
[00:46:52.069] literally hit candidate one. The rest of
[00:46:54.230] this should be fine. At the moment, it's
[00:46:57.670] just upscaling to 1 megapixel.
[00:47:00.630] Uh again, you can you can try higher if
[00:47:03.190] you wish. It's completely up to you. Uh
[00:47:05.910] I can't guarantee cuz I've only gone up
[00:47:07.589] to one megapixel with mine. I've not
[00:47:10.150] tested past it yet.
[00:47:13.670] Uh so let's hit run.
[00:47:15.190] There we go. So it's straight into the
[00:47:15.200] There we go. So it's straight into the refine.
[00:47:17.349] refine.
[00:47:18.950] Uh and this I think was one of the
[00:47:21.670] things on the comments was that it would
[00:47:23.510] generate the whole thing again. So
[00:47:26.550] that's been fixed. So now whichever one
[00:47:29.670] of these you hit, it will refine that
[00:47:32.550] latent and not regenerate from the
[00:47:34.870] beginning again.
[00:47:37.349] Um, and then don't forget once this is
[00:47:38.710] finished and if you want to use another
[00:47:42.150] seed hunt to turn the button off,
[00:47:44.710] otherwise it will just automatically use
[00:47:48.309] candidate one on a fresh seed hunt. Uh,
[00:47:49.670] I'll get back to you once this bit's
[00:47:49.680] I'll get back to you once this bit's finished.
[00:47:51.990] finished.
[00:47:55.030] Okay, here's the output now from the
[00:47:57.430] second stage.
[00:48:30.549] And we can see there that we're on 1376
[00:48:32.710] x 768
[00:48:35.030] which is the 1 megapixel count. So the
[00:48:45.510] Okay. And I think that's
[00:48:48.309] working pretty well.
[00:48:48.319] working pretty well. Um,
[00:48:50.710] Um,
[00:48:53.030] and I think most of the comments
[00:48:55.750] regarding the seed hunt have pretty much
[00:48:58.309] been addressed now. If there's something
[00:49:00.710] else you find, then obviously let me
[00:49:02.790] know. I think that's pretty much the
[00:49:05.670] seed hunt thing addressed.
[00:49:08.630] So, there was another comment saying
[00:49:11.190] that the cloned audio doesn't work with
[00:49:13.750] Seed Hunt or doesn't pass through Seed
[00:49:15.109] Hunt. So, we're going to test that now
[00:49:16.630] and see.
[00:49:20.069] Uh, what happens? So, I've dropped in a
[00:49:21.990] voice reference
[00:49:26.230] and I don't need it to be that long
[00:49:29.030] for the reference. So, we just use that.
[00:49:31.190] I've got the same character. I've got
[00:49:33.510] the same scene, but I've added extra
[00:49:36.390] dialogue. So, in the original one, there
[00:49:38.870] was only dialogue in cut two of each
[00:49:41.430] chunk. There's now an extra sentence in
[00:49:44.470] each. So, we've got plenty of um
[00:49:46.870] dialogue and we're doing two chunks so
[00:49:50.470] we can see if it carries over and I've
[00:49:52.069] changed nothing else. So, we've still
[00:49:55.190] got the seed hunt turned on and we're
[00:49:57.030] still going to do four candidates. Still
[00:49:58.950] got the upscaling.
[00:50:01.030] So, nothing else has changed other than
[00:50:04.630] the audio and the dialogue. So, we'll
[00:50:07.349] test this now. So, we need to make sure
[00:50:09.910] that's turned off so it doesn't
[00:50:09.920] that's turned off so it doesn't automatically
[00:50:11.670] automatically
[00:50:14.309] upscale candidate one.
[00:50:27.030] Okay, so we've got the new uh candidates
[00:50:30.710] um that are going to have more
[00:50:32.470] audio. Now, we know that the audio
[00:50:35.670] doesn't really show that well in uh Seed
[00:50:37.750] Hunt when it's the first stage sampling
[00:50:43.510] Yeah, there you go. It's not great. So,
[00:50:45.109] we're just going to go off the image and
[00:50:48.630] then test it by the results. So, we will
[00:50:51.589] go with
[00:50:56.870] um okay, let's let's go with number
[00:50:56.880] um okay, let's let's go with number three.
[00:50:59.430] three.
[00:51:01.430] So, let's go with this one.
[00:51:04.150] Right. So, click number three. Pass it
[00:51:06.870] through. Let's see what the if the audio
[00:51:10.470] cloning holds up.
[00:51:14.710] Okay. So, this is the output from the
[00:51:19.109] voice clone seed hunt test. And
[00:51:22.390] the video looks pretty cool. And I'm
[00:51:30.069] actual audio first
[00:51:33.670] and then the video after this. So if you
[00:51:35.109] listen to this,
[00:51:37.190] imagine having your own AI version of
[00:51:38.950] you working around the clock, never
[00:51:40.790] sleeping, never stopping.
[00:51:43.030] That's the actual voice that we've been
[00:51:45.190] using as reference.
[00:51:50.069] And then this is the video.
[00:51:51.829] Something's wrong. The pressure is
[00:51:51.839] Something's wrong. The pressure is dropping.
[00:51:53.510] dropping.
[00:52:02.230] I need to isolate it before the damage
[00:52:04.309] spreads. Show me the full structural
[00:52:07.349] scan. Ready structural scan.
[00:52:17.990] There. I found it. closing the emergency
[00:52:18.950] bulkhead now.
[00:52:22.069] And I think that works pretty well. Um,
[00:52:24.069] at least from me listening to it, it
[00:52:27.270] seemed like the voice cloned well. Um,
[00:52:29.589] and it sounded like the reference. And
[00:52:32.470] that's over two chunks. So, I think as
[00:52:34.549] far as I can tell, that is fixed as
[00:52:37.030] well. So, let's move on to the next
[00:52:37.040] well. So, let's move on to the next thing.
[00:52:39.349] thing.
[00:52:41.190] Okay. So, the next thing we're going to
[00:52:44.790] look at is first frame, last frame. Um,
[00:52:46.470] there was a com one of the comments said
[00:52:48.470] that as soon as it changed to it, it
[00:52:48.480] that as soon as it changed to it, it crashed.
[00:52:49.990] crashed.
[00:52:52.870] That I don't really I don't really know.
[00:52:55.990] It doesn't crash when I change it. Maybe
[00:52:57.750] there's a conflict with something in
[00:53:01.750] inside your own custom nodes. Um, I
[00:53:03.750] can't really answer that one. It doesn't
[00:53:06.309] it doesn't crash when I when I do it, so
[00:53:09.109] I can't really see it as a a problem
[00:53:14.390] that I can solve. Um, okay. So,
[00:53:16.230] first frame, last frame, pretty
[00:53:18.230] straightforward. We are going to
[00:53:18.240] straightforward. We are going to generate
[00:53:20.630] generate
[00:53:23.190] with seed hunt.
[00:53:26.549] Let's just put that to the 42. Uh, we're
[00:53:27.589] going to generate with seed hunt. So,
[00:53:29.990] we're going to do four candidates. And
[00:53:31.990] you can see I did a a test version
[00:53:34.470] before. Um,
[00:53:37.270] latent only scouting. Two-stage sampler
[00:53:39.750] is on. We've got a pretty
[00:53:41.910] straightforwardish prompt.
[00:53:45.190] uh two chunks just to show that it works
[00:53:47.109] over chunking.
[00:53:49.190] And we've got the first frame here and
[00:53:51.990] last frame here.
[00:53:53.430] So, we're going to start off here and
[00:53:57.990] end up on a really closeup crop. Um,
[00:54:01.829] another comment was about using the
[00:54:03.750] reference audio.
[00:54:06.630] Um, on first frame, last frame, it
[00:54:08.950] doesn't do that. It's if you look at the
[00:54:11.990] official node there is no reference
[00:54:15.190] um there isn't a reference sort of node
[00:54:18.470] in part to that node I should say um it
[00:54:23.670] is purely first frame last frame and
[00:54:26.630] yeah so
[00:54:29.190] this is just purely going to be two
[00:54:32.150] images using the prompt to get from the
[00:54:34.390] first image to the last image. Now, it
[00:54:36.230] does work
[00:54:39.190] in my version. It works with the
[00:54:42.470] chunking. So, whatever you put in as the
[00:54:44.870] first frame is going to start chunk one
[00:54:47.270] as the first frame. Whatever you put as
[00:54:49.670] the last frame will be the end of
[00:54:53.190] whatever the last chunk is. So, if you
[00:54:55.589] do two chunks like this, that last frame
[00:54:57.349] will always be the last frame of the
[00:54:59.750] second chunk. If you do three chunks,
[00:55:01.109] it'll be the last frame of the third
[00:55:04.710] chunk. Um that's how I've designed it to
[00:55:09.109] work so that it's uh a continuation from
[00:55:11.750] each chunk. So chunk one, it will start
[00:55:14.549] with the start image. It will finish and
[00:55:18.150] the end image from chunk one will become
[00:55:20.630] the start image, first frame image of
[00:55:23.750] chunk two and it will continue that way
[00:55:26.470] until it gets to the end of your chunk.
[00:55:31.030] If that makes sense. Um, okay. So, we
[00:55:34.309] are going to do a run with this. I'm
[00:55:35.990] going to turn this off cuz I've made
[00:55:38.870] this mistake before. Um, we're going to
[00:55:41.829] turn seed hunt on.
[00:55:44.870] Going to turn single image
[00:55:48.230] or non seed hunt off.
[00:55:57.030] Okay. So once these have generated, I
[00:55:59.510] will get back to you with the newest
[00:55:59.520] will get back to you with the newest candidates.
[00:56:01.990] candidates.
[00:56:06.069] Okay. So we've got the four candidates
[00:56:16.549] There we go.
[00:56:25.270] Okay. So, yep, they're all slightly
[00:56:25.280] Okay. So, yep, they're all slightly different.
[00:56:31.270] And let's just check where they get to
[00:56:36.150] And they're pretty much following the
[00:56:36.160] And they're pretty much following the prompt.
[00:56:37.670] prompt.
[00:56:45.270] And when I say splice, I mean between
[00:56:51.510] And that was the last frame. So, it
[00:56:53.510] ended pretty well there. So, let's just
[00:56:53.520] ended pretty well there. So, let's just do
[00:56:55.430] do
[00:56:59.589] uh not number three.
[00:57:02.630] Let's do number one.
[00:57:09.910] Okay. So, we're going to do number four.
[00:57:12.470] And we're going to
[00:57:14.950] hit refine on that.
[00:57:16.470] And this will do the second stage
[00:57:21.270] sampling on the number four candidate.
[00:57:23.109] and I will be back with you as soon as
[00:57:26.470] that has finished generating.
[00:57:30.630] Okay, so we have our render.
[00:58:05.829] Are you watching me? Are you looking at
[00:58:05.839] Are you watching me? Are you looking at me?
[00:58:07.589] me?
[00:58:07.599] me? >> Cool.
[00:58:09.270] Cool.
[00:58:12.150] Okay, so
[00:58:12.160] Okay, so let's
[00:58:14.230] let's
[00:58:15.990] There is a tiny glitch. You may have
[00:58:18.470] noticed it at the scene.
[00:58:18.480] noticed it at the scene. So
[00:58:20.309] So
[00:58:24.069] with the seed hunt version,
[00:58:24.079] with the seed hunt version, it
[00:58:26.950] it
[00:58:29.109] it basically because it's got hold the
[00:58:32.150] latence until you refine it. There can
[00:58:36.230] be a slight glitch just at the seam. So
[00:58:37.990] you have to most things you probably
[00:58:39.510] won't be aware of it. This one the
[00:58:42.230] background stays the same. So, it's a
[00:58:44.390] little bit more obvious, but it is only
[00:58:44.400] little bit more obvious, but it is only minuscule.
[00:58:45.990] minuscule.
[00:58:46.000] minuscule. Um,
[00:58:47.589] Um,
[00:58:50.069] however, if you decide that that is the
[00:58:54.150] one for you in terms of render, yeah,
[00:58:56.870] you can see it there slightly.
[00:59:01.430] Um, then the way around it is to take
[00:59:04.309] the seed that you
[00:59:06.630] uh just used
[00:59:09.750] and do another render with that same
[00:59:09.760] and do another render with that same seed.
[00:59:10.950] seed.
[00:59:15.109] The single pass, well it's Tuesday
[00:59:16.789] sampler, but the single pass in terms of
[00:59:20.870] it not being a seed hunt one is a
[00:59:24.150] continual is a continuous generation. So
[00:59:26.870] you don't get the same problem with
[00:59:28.789] join. So I'm going to do that one as
[00:59:31.109] well. Then put them both side by side
[00:59:34.870] just so you can see the difference.
[00:59:47.430] Bring that one back
[00:59:51.349] and turn this off. Turn this off.
[00:59:54.549] And I'm going to need the seed. So, bear
[00:59:56.950] with me a second. So, if you go into
[00:59:58.789] your log,
[01:00:01.750] you'll find the seed.
[01:00:01.760] you'll find the seed. So,
[01:00:03.349] So,
[01:00:06.710] where is it? Seed. There we go. 3000.
[01:00:29.349] Yeah. Okay. Yeah. There it is. There
[01:00:32.470] again as well on the second stage. Okay.
[01:00:37.190] Brilliant. So get rid of that.
[01:00:39.430] Pop that in.
[01:00:41.990] And we'll hit run. And we should get a
[01:00:44.309] cleaner output.
[01:00:46.150] It is a long way about doing it. It
[01:00:48.470] depends on how much you bothered and how
[01:00:50.230] much the
[01:00:52.390] how much that join bothers you. If it
[01:00:54.150] bothers you too much, then you can just
[01:00:56.549] do this. You still have the advantage of
[01:00:58.230] seeing the different seeds and working
[01:01:06.309] remembering as well that this is quite a
[01:01:08.470] simple prompt. So there's there's
[01:01:09.910] probably not a lot to choose from
[01:01:14.230] between the four, but um yeah, if you
[01:01:16.390] want it to be
[01:01:19.589] more seamless, then this is the way to
[01:01:24.390] do it. Uh I'll put both side by side uh
[01:01:27.670] once this is generated.
[01:01:30.710] Okay, so this is the
[01:01:32.789] nonse hunt version but using the same
[01:01:32.799] nonse hunt version but using the same seed.
[01:01:34.789] seed.
[01:01:51.510] I'm going to put them side by side so
[01:01:53.990] you can see.
[01:01:56.470] So look here. So, if we move this across
[01:01:59.109] a minute
[01:02:23.990] once we get to roughly where the join
[01:02:33.109] there.
[01:02:36.230] Doesn't do it on the uh nonse hunt
[01:02:52.630] Uh, okay. So, that's the
[01:02:55.430] first frame, last frame, seed hunt, and
[01:03:01.030] nonseed hunt. So, um, I think as far as
[01:03:02.710] I'm concerned with that, it works
[01:03:09.030] Um,
[01:03:12.069] yeah. Okay. So,
[01:03:16.069] next test. Um, I'm going to have a quick
[01:03:17.829] look through my notes again and I will
[01:03:20.470] get on to the next part of this video.
[01:03:23.109] Okay, back again.
[01:03:26.470] So, the seed hunt thing was bugging me.
[01:03:29.510] They had the glitch. So, I've spent the
[01:03:32.630] last couple of hours testing various
[01:03:36.230] methods of doing it and we've got rid of
[01:03:40.230] the glitch. So,
[01:03:42.870] ignore what I said before. Seed Hunt now
[01:03:46.150] works and there is no glitch between
[01:03:49.829] seams. Um, the downside is it does take
[01:03:51.910] an extra 2 minutes.
[01:03:54.150] um the mechanism to make it do it
[01:03:58.069] without the glitch means that it takes a
[01:04:01.349] little bit longer to regenerate as it
[01:04:04.309] has to regenerate some of the
[01:04:06.950] previous latents when it goes through
[01:04:08.870] the refiner.
[01:04:13.349] So I think all in all it took for this
[01:04:16.789] 30 secondond video it took about
[01:04:20.309] um originally it took about 11 minutes
[01:04:23.029] and now it takes 13 minutes. So it's a
[01:04:25.430] couple of minutes extra but it does mean
[01:04:27.349] that there's no glitch and that you can
[01:04:30.150] use this one so you don't then have to
[01:04:30.160] use this one so you don't then have to regenerate
[01:04:32.150] regenerate
[01:04:34.870] using the nonseed hunt version. You can
[01:04:36.549] use this one straight out of the box. So
[01:04:38.630] if we look
[01:04:38.640] if we look closely
[01:04:51.589] um you'll see that there is now no
[01:04:55.029] difference at the seam.
[01:04:57.829] So the seam is
[01:05:00.789] roughly around here
[01:05:02.390] and there's no difference between the
[01:05:02.400] and there's no difference between the two.
[01:05:05.029] two.
[01:05:06.950] And then when she works walks forward,
[01:05:09.430] we know we're in the second chunk. So
[01:05:12.710] yeah, works fine.
[01:05:12.720] yeah, works fine. Okay.
[01:05:14.470] Okay.
[01:05:17.589] Just wanted to make that extra
[01:05:19.670] bit there because
[01:05:21.670] it is frustrating when something is so
[01:05:23.589] close to working.
[01:05:29.829] Okay. So the next thing I want to show
[01:05:34.390] you is a new mode that I've done on this
[01:05:37.670] version, hybrid mode.
[01:05:41.349] So hybrid mode can use both first frame,
[01:05:44.150] last frame or reference.
[01:05:44.160] last frame or reference. Um,
[01:05:45.750] Um,
[01:05:50.230] and basically the way it works,
[01:05:53.190] I've updated some of the
[01:05:55.670] the chunks to work slightly differently.
[01:05:58.230] So per chunk you can choose whether that
[01:06:00.150] is first frame, last frame or reference.
[01:06:02.710] We're using reference on this first one.
[01:06:02.720] We're using reference on this first one. Um
[01:06:04.230] Um
[01:06:07.430] and depending which mode you use will
[01:06:10.390] show a different set of reference images
[01:06:13.589] underneath. So on the normal versions
[01:06:15.990] that we've seen, we've got the reference
[01:06:18.950] images at the bottom. On hybrid mode,
[01:06:20.710] I've changed it so these are shared
[01:06:24.069] assets. So these bottom row uh still
[01:06:28.549] functional but they're shared and
[01:06:30.870] so like for example
[01:06:34.069] reference one here is this character and
[01:06:36.789] this one is so it's using all applicable
[01:06:40.870] chunks. So if we had three chunks that
[01:06:43.910] were reference and this was ticked she
[01:06:47.029] would be reference one in all of those.
[01:06:47.039] would be reference one in all of those. Um,
[01:06:49.029] Um,
[01:06:51.670] if you don't want her to be the
[01:06:53.589] character in all three, then you turn
[01:06:57.270] this off and you just use it per
[01:07:00.309] reference one per chunk. So you could
[01:07:02.470] have if you had all if you had three
[01:07:03.990] chunks with these three characters, for
[01:07:06.630] example, you could you would switch off
[01:07:08.470] the shared
[01:07:12.150] um asset reference one and you would
[01:07:14.630] just have reference one in each chunk as
[01:07:16.630] a different character. if that makes
[01:07:19.670] sense. Um,
[01:07:23.270] and also the
[01:07:26.069] all the audio is also linked as well.
[01:07:31.750] So, if I drop an audio track in here,
[01:07:35.190] we'll see if I've got one.
[01:07:37.750] Okay. So, let's just use just use that
[01:07:40.789] one. So, the audio track comes in here.
[01:07:44.230] If we use this as a shared one as well,
[01:07:46.950] it's going to assign itself
[01:07:46.960] it's going to assign itself here.
[01:07:48.630] here.
[01:07:54.230] So when you've got shared assets ticked,
[01:07:57.190] it grays them out on the chunk on each
[01:08:00.950] chunk because it's shared. So that means
[01:08:03.910] that each chunk that you open that'll be
[01:08:06.710] a reference chunk for example
[01:08:09.829] will have a grade out reference one and
[01:08:12.549] audio one while you have them ticked
[01:08:12.559] audio one while you have them ticked here.
[01:08:14.630] here.
[01:08:16.789] If you don't want them shared per chunk
[01:08:19.030] then you untick these and you just add
[01:08:21.430] them per chunk instead.
[01:08:24.550] But the reason I'm doing this is because
[01:08:27.030] it makes more sense in terms of using
[01:08:29.189] the hybrid function.
[01:08:29.199] the hybrid function. So,
[01:08:31.269] So,
[01:08:35.189] first of all, we're going to do this
[01:08:37.189] generation, which is 15 seconds. We're
[01:08:39.349] going to use three characters. And just
[01:08:42.709] for the sake of showing you, um, we're
[01:08:44.789] going to use the reference one, the
[01:08:48.470] character here as the shared asset, uh,
[01:08:52.950] the location as a shared asset, and that
[01:08:55.349] will gray out these two.
[01:08:56.789] In fact, let's get rid of that audio
[01:09:04.950] And then these two characters are just
[01:09:08.229] occupying reference two and three. We've
[01:09:10.070] already got a prompt in here. And each
[01:09:11.749] one of them is going to say something.
[01:09:14.149] So you can see here it's only a
[01:09:17.269] 15-second uh video. So ref one is going
[01:09:19.910] to talk first, then in the second cut
[01:09:23.510] ref, the third cut ref.
[01:09:25.269] So all of them should get a bite. And
[01:09:27.669] it'll also show
[01:09:30.870] that the little reference tags here for
[01:09:32.550] audio should work for all three
[01:09:32.560] audio should work for all three characters.
[01:09:34.789] characters.
[01:09:37.189] Then once we've generated that one,
[01:09:39.669] we're going to extend it by adding a
[01:09:42.950] second chunk, but we're going to
[01:09:44.470] um we're going to use that second chunk.
[01:09:48.550] It's going to be first, last. So it's
[01:09:51.829] it's kind of just sort of it's it's a
[01:09:54.070] bit of a work in progress. I won't lie,
[01:09:56.550] but I've had a look at it so far and it
[01:09:58.870] works pretty well. Also, something else
[01:10:00.630] on this hybrid node, which I'll probably
[01:10:03.270] pass along to the other modes as well.
[01:10:06.550] I've also added guides. Uh, I watched a
[01:10:08.550] video the other day and someone was
[01:10:12.470] using the guide node to sort of well to
[01:10:16.470] guide the video. Um, so it's
[01:10:18.550] automatically got four added. Obviously,
[01:10:20.950] if you don't occupy them, then they
[01:10:23.590] won't do anything. But you can add a
[01:10:26.310] guide image in and you can say at what
[01:10:30.310] point during the um generation you want
[01:10:33.270] that to happen.
[01:10:35.270] Uh I need to experiment with that. It's
[01:10:37.590] a new feature. Uh you guys are welcome
[01:10:40.790] to experiment with it. But in theory you
[01:10:42.950] would have to generate
[01:10:45.510] so imagine a first last frame scenario.
[01:10:47.030] So, if you've got a first last frame
[01:10:49.990] scenario, a guide image might be a third
[01:10:54.470] or fourth image that can fit in between
[01:10:57.189] your first and last frame.
[01:10:57.199] your first and last frame. Um,
[01:10:58.790] Um,
[01:11:01.830] and what should happen is the first
[01:11:04.790] frame starts, goes up to the point of
[01:11:08.310] the guide, then that guide image should
[01:11:11.030] be what renders and then from there
[01:11:14.550] it'll render onwards to the final frame.
[01:11:17.030] Uh, but I feel like that's a whole
[01:11:19.110] different video. So, I'm going to gloss
[01:11:21.110] over that for now. But I just wanted
[01:11:22.709] when you get this workflow, you'll see
[01:11:24.310] it there. So, I just wanted you to
[01:11:26.390] understand what it was for. The one
[01:11:28.470] caveat we might have with the guide
[01:11:31.030] images is the timings.
[01:11:32.790] So, because we're using a chunking
[01:11:34.950] system that
[01:11:38.630] um seamlessly chunks from one chunk to
[01:11:41.669] the next, there is an overlap of frames
[01:11:44.870] that happens. So, it shouldn't let you
[01:11:47.110] go into that. So, if you find that it's
[01:11:48.709] not letting you do it at a certain
[01:11:50.550] point, it's probably because it's going
[01:11:52.870] into the overlap frames and it's been
[01:11:55.830] hardcoded not to let you do that.
[01:11:58.870] Uh, okay. So, back on with this one. So,
[01:12:00.550] we're going to just generate this first
[01:12:02.149] just so we can see where we're up to and
[01:12:04.390] see that the audio works and then move
[01:12:06.229] on to the next bit and I can then show
[01:12:10.550] you the second chunk with uh the first
[01:12:14.229] first frame, last frame. Um, not going
[01:12:16.390] to use seed hunt with this. I'm just
[01:12:18.630] going to generate it straight out just
[01:12:21.510] so we uh you're not waiting for ages for
[01:12:21.520] so we uh you're not waiting for ages for it.
[01:12:30.550] Okie do. So, this is the first render.
[01:12:32.630] The coolant pressure finally stabilized.
[01:12:33.110] Looks pretty cool.
[01:12:33.910] How was your shift?
[01:12:35.270] I will drop the video properly
[01:12:36.709] until the western sensors detected
[01:12:36.719] until the western sensors detected movement.
[01:12:38.470] movement.
[01:12:42.630] Uh, yeah, there we go. That's my The guy
[01:12:46.390] running in was pretty good.
[01:12:48.229] Okay. When it's further back, it's a bit
[01:12:48.239] Okay. When it's further back, it's a bit dodge,
[01:12:54.709] but higher resolution might take care of
[01:12:54.719] but higher resolution might take care of that.
[01:13:00.070] But all three characters speak their
[01:13:01.830] lines in the right time, in the right
[01:13:09.430] And we have the final image from that
[01:13:09.440] And we have the final image from that here.
[01:13:11.189] here.
[01:13:12.550] Uh, which is what we do on all the
[01:13:14.950] workflows. It automatically saves the
[01:13:16.950] final frame. So, we know we've already
[01:13:19.030] got it and we can see what resolution it
[01:13:21.510] is. So, that's good. We could use that
[01:13:26.070] as a first frame. Um, the beauty of this
[01:13:29.510] system though is
[01:13:31.830] when it when it goes from one chunk to
[01:13:34.310] the next, it uses the last frame of the
[01:13:38.470] previous chunk as the first frame anyway
[01:13:39.830] when it's in first frame last frame
[01:13:42.790] mode, sorry, I should say. So that will
[01:13:45.350] automatically happen. So if I change
[01:13:47.590] this to
[01:13:57.990] it adds in the next chunk.
[01:13:59.910] And if we turn that to first frame, last
[01:14:03.990] frame, it changes the UI slightly. So on
[01:14:06.229] this one, on first frame, last frame,
[01:14:07.590] obviously we can't use the reference
[01:14:10.870] images, but we can still use guides and
[01:14:13.510] the first frame, last frame. Now, on
[01:14:15.110] this particular one, I'm not going to
[01:14:17.750] add a first frame because what we want
[01:14:22.390] it to do is continue from chunk one. Um,
[01:14:25.110] and we don't want some sort of jump cut.
[01:14:26.950] So, the first frame is going to come
[01:14:30.950] from the last frame of chunk one. What
[01:14:34.790] we're going to do is add a last frame
[01:14:38.070] so that um when chunk two finishes, it
[01:14:40.790] finishes on whatever that frame is. So,
[01:14:43.430] I'm going to go and grab that now and
[01:14:48.070] then add it in and add to the prompt.
[01:14:52.149] Okay. So, now we have chunk two. So,
[01:14:53.750] we're going to use first frame, last
[01:14:57.110] frame for chunk two. Um, and you can see
[01:15:01.030] down here we've got the boxes. So, we're
[01:15:03.590] not using a first frame for this as it's
[01:15:05.910] the the first frame is going to be the
[01:15:07.990] last frame from chunk one. And we've
[01:15:09.750] added what the last frame is going to be
[01:15:12.550] here. Um, we could add guides to this as
[01:15:15.910] well um at various timings, but as I
[01:15:17.750] mentioned, I'm not going to try playing
[01:15:19.910] with that just yet. Uh, we've added a
[01:15:23.510] prompt in, we've added some dialogue,
[01:15:27.510] and we've ticked to the references. Now,
[01:15:30.950] I'm assured this might work, but as we
[01:15:32.709] know with first frame, last frame, there
[01:15:36.470] are no reference images inputs for that
[01:15:36.480] are no reference images inputs for that node.
[01:15:38.550] node.
[01:15:43.030] But I'm told that potentially the audio
[01:15:45.830] will work. So, I've wired it up this way
[01:15:49.590] anyway and we'll see. And the
[01:15:53.669] um I've also changed the reference audio
[01:15:56.229] slightly uh potentially to help out. And
[01:15:58.470] it's the same in reference and in first
[01:16:01.030] frame last frame. So, normally whenever
[01:16:03.110] there's a dialogue in inverted commas,
[01:16:05.270] these three boxes or however many
[01:16:07.510] reference characters you have boxes will
[01:16:10.070] appear and you tick the one that is
[01:16:10.080] appear and you tick the one that is talking.
[01:16:11.590] talking.
[01:16:14.070] Um, I've also now just added this who's
[01:16:14.080] Um, I've also now just added this who's speaking
[01:16:15.830] speaking
[01:16:18.630] um dialogue bit. So, whatever dialogue
[01:16:21.669] you put into your cut will come up here.
[01:16:24.870] And in theory, you should be able to
[01:16:28.070] then have a two-way conversation within
[01:16:29.750] a certain cut.
[01:16:32.790] So if I put
[01:16:32.800] So if I put um
[01:16:54.310] that there it's you can see it's brought
[01:16:57.910] up another set of uh references. We can
[01:17:01.189] turn that one off and turn that one on.
[01:17:04.550] And now technically in that particular
[01:17:04.560] And now technically in that particular scenario,
[01:17:06.149] scenario,
[01:17:08.790] this would
[01:17:10.870] this would instigate a two-way
[01:17:14.390] conversation and the references would be
[01:17:16.950] the correct person speaking. So maybe
[01:17:19.669] another video for that. But I thought
[01:17:23.030] that was a little bit more helpful.
[01:17:24.470] So I'm going to get rid of that for now.
[01:17:28.470] So if we delete that, that should just
[01:17:30.950] remove itself.
[01:17:35.270] Okay. So back onto this though. So
[01:17:37.110] this bit is a little bit of an
[01:17:39.750] experiment because as I've already
[01:17:41.910] mentioned, there are no uh reference
[01:17:45.510] audio no uh sockets on the first last
[01:17:47.430] frame node. So we'll see how that gets
[01:17:50.790] on and whether or not it gets to here.
[01:17:53.590] So that is the final frame
[01:17:57.669] for this chunk. Okay. So I'll get back
[01:18:10.070] Okay. So that ran and unless it's a
[01:18:12.550] complete coincidence,
[01:18:18.070] it um the dialogue seemed to be correct.
[01:18:27.750] the coolant pressure finally stabilized.
[01:18:29.270] How was your shift?
[01:18:31.590] Quiet until the western sensors detected
[01:18:31.600] Quiet until the western sensors detected movement.
[01:18:44.149] Wait. Show me your palm. No. Stay away
[01:18:55.830] You are a runner.
[01:18:58.310] Okay, brilliant. And that last frame is
[01:19:00.229] the matching
[01:19:03.510] image for what we put in last frame.
[01:19:08.310] So that worked pretty well. Okay, so
[01:19:10.070] something else that was mentioned in the
[01:19:11.830] comments, which is something I can't
[01:19:15.030] really do much about, is whisper speed.
[01:19:17.830] Um, so Whisper is a model that
[01:19:22.709] transcribes um audio and it's got tiny
[01:19:25.830] bass, small and medium, and there is a
[01:19:28.790] large version as well potentially. Uh,
[01:19:32.470] the difference between them is
[01:19:34.870] the tiny one is the fastest, but it's
[01:19:37.030] the least accurate. The medium one on
[01:19:38.950] here is the most accurate, but it's a
[01:19:42.229] bit slower. So, in terms of speeding up
[01:19:44.709] the whisper model, those are the
[01:19:46.870] options. It's not something that I can
[01:19:49.270] change in here. That being said, we
[01:19:52.310] haven't done a lip sync test. So, we're
[01:19:56.149] going to um we're going to try it out.
[01:19:59.030] Okay. So, I just had to flip this on to
[01:20:02.070] the correct mode cuz we were on
[01:20:02.080] the correct mode cuz we were on um
[01:20:03.590] um
[01:20:07.350] hybrid. So, I've changed this over to
[01:20:09.110] reference mode. So, we're going to do
[01:20:13.510] this lip sync on that. And
[01:20:16.310] basically, so as I mentioned with
[01:20:20.709] Whisper, it can transcribe stuff. Um,
[01:20:24.149] and we're going to set it to medium. And
[01:20:26.310] I've put a reference song in at the top
[01:20:26.320] I've put a reference song in at the top here,
[01:20:28.149] here,
[01:20:31.030] and it's 193 seconds, so it's 3 minutes
[01:20:32.310] long. We're not going to generate a
[01:20:35.990] 3minute video. It's take ages. Um but
[01:20:40.149] what we will do is generate a
[01:20:42.550] um 60-second
[01:20:42.560] um 60-second video
[01:20:45.510] video
[01:20:45.520] video and
[01:20:51.910] okay
[01:20:53.669] and we've got it on lip sync mode there.
[01:20:55.270] Right. Okay. So we've got the audio
[01:20:58.310] track there and we've set it to 60. Now,
[01:21:00.870] this audio track,
[01:21:03.189] it's not essential,
[01:21:07.189] um, but it does help whisper. So, this
[01:21:09.189] is the same track, but with the song
[01:21:13.030] stripped out. So, it's literally the,
[01:21:15.750] um, dialogue or words for the song
[01:21:53.990] Okay. So, basically it's the same track.
[01:21:55.910] I've just stripped out the actual song
[01:21:59.030] itself. Um, that isn't automatic. You're
[01:22:01.110] going to need to do that on a separate
[01:22:03.750] workflow first. Then just save the two
[01:22:06.470] tracks. Um, and just call one of them
[01:22:09.110] vocals only. Um, and you put it in there
[01:22:10.950] and then Whisper has a better chance of
[01:22:13.510] actually getting transcribing the right
[01:22:18.629] words. Um, otherwise it can get muddled
[01:22:20.310] when it's trying to listen to the words
[01:22:23.030] and the track at the same time.
[01:22:26.229] And then we hit transcribe.
[01:22:28.149] Now, this might take a minute, so I'm
[01:22:29.669] going to just pause it and come back to
[01:22:33.430] you. Okay, that took a minute or so to
[01:22:33.440] you. Okay, that took a minute or so to transcribe.
[01:22:35.510] transcribe.
[01:22:39.189] So, what have we got now? So, we've got
[01:22:44.229] the transcription from the 60 seconds.
[01:22:47.350] So, it's got all the lines here. Uh,
[01:22:49.189] there you go. Your coffee cup's still by
[01:22:51.830] my bed. Go to sleep in my head. So, it's
[01:22:54.310] got basically all the lyrics up until
[01:22:57.270] that point. And then it's got two more
[01:22:59.910] things underneath. We've got insert as
[01:23:01.830] timed cuts.
[01:23:05.830] Now, what this does is if you click
[01:23:05.840] Now, what this does is if you click this,
[01:23:07.910] this,
[01:23:10.229] it will create however many chunks it
[01:23:13.510] needs for 60 seconds. So, technically
[01:23:16.310] each chunk is set to 15 seconds at the
[01:23:18.390] moment. So, you'd end up with four
[01:23:22.229] chunks. and it'll insert the timed cuts
[01:23:26.229] in the correct timestamp
[01:23:28.629] within each chunk.
[01:23:33.430] Okay? So that way when the video
[01:23:36.470] generates from chunk one to chunk two,
[01:23:39.270] you end up with a seamless transition
[01:23:42.950] and the wording or lyrics will be in the
[01:23:45.750] correct timestamp.
[01:23:50.390] So that's this is kind of how H3 works
[01:23:53.030] with uh lip sync.
[01:23:58.149] Um like one infinite workflow, infinite
[01:24:01.350] talk. Um you don't need to do any of
[01:24:03.830] that. You literally put in the audio
[01:24:06.470] track or song and it will sync your
[01:24:09.110] video generation to that. This doesn't
[01:24:10.950] work the same way. I've tried it. It
[01:24:12.950] doesn't work the same way. you have to
[01:24:15.350] have the
[01:24:18.229] lyrics or the dialogue
[01:24:21.350] in the correct place for it to pick it
[01:24:25.270] up and guide it so it syncs at the right
[01:24:25.280] up and guide it so it syncs at the right point.
[01:24:26.790] point.
[01:24:30.229] So, as I said, if you hit insert a time
[01:24:35.590] cuts, it's going to give you uh
[01:24:35.600] cuts, it's going to give you uh this.
[01:24:37.750] this.
[01:24:41.270] So, we've got four chunks.
[01:24:43.270] And I don't know if you can see it from
[01:24:46.709] there. Okay, if you look closer, it's
[01:24:48.470] basically even got little tiny slivers
[01:24:50.709] of a cut. So, there's got one, two,
[01:24:55.189] three, four, five cuts in chunk two. And
[01:24:58.229] those all correspond to the right time
[01:25:01.750] when the chosen words should be spoken.
[01:25:05.110] And I've added the prompt to this. So,
[01:25:06.950] it doesn't appear like this. the chunks
[01:25:09.990] will appear and what else will appear is
[01:25:14.870] the the lyric in inverted commas in
[01:25:16.629] here. So that's all you'll see in each
[01:25:19.030] cut. The rest of it will be empty. You
[01:25:19.990] have to add your prompt to it
[01:25:23.350] afterwards, but it will show up with the
[01:25:28.950] reference um uh tag thing button
[01:25:32.149] so that you can uh click it. And I think
[01:25:33.990] it's auto automatically doing that when
[01:25:36.229] there's only one reference in there.
[01:25:38.229] It's automatically doing reference one.
[01:25:41.350] If it's shaded out, just click it.
[01:25:43.510] Uh something else I've had it do as well
[01:25:43.520] Uh something else I've had it do as well is
[01:25:45.590] is
[01:25:48.390] pop the text here. It's a bit small on
[01:25:53.189] this, but it's there. Um and that will
[01:25:56.950] be all the lyrics for the 60-cond video.
[01:26:00.229] Now in terms of the prompt you know it's
[01:26:02.470] it's up to you you know you can prompt
[01:26:04.550] it to do whatever you want it to do.
[01:26:08.629] What I have done under here so under
[01:26:11.669] insert at time chunks
[01:26:14.550] we've also got
[01:26:14.560] we've also got this.
[01:26:17.030] this.
[01:26:21.910] So, something I found useful was
[01:26:24.149] um having
[01:26:26.070] having this to copy and paste and give
[01:26:29.990] to my LLM when I'm creating the prompt.
[01:26:34.470] So, I can give the LLM the um
[01:26:37.669] uh background image, the character
[01:26:40.550] sheet, and now I can give it this with
[01:26:44.070] the idea of what I want it to do in the
[01:26:47.590] prompt. So, I'll give it a vague sort of
[01:26:50.550] um idea of what the video should look
[01:26:53.189] like and then it can prompt for me using
[01:26:53.199] like and then it can prompt for me using the
[01:26:54.709] the
[01:26:57.189] prompt skill, the H3 minimize prompt
[01:27:01.510] skill. Um, but what this does is it
[01:27:04.550] copies exactly where those chunks lie,
[01:27:06.790] where the cuts lie within each chunk.
[01:27:09.910] So, you can see there 0 in chunk 2 that
[01:27:12.790] tiny slither of one was from 0 to 02
[01:27:12.800] tiny slither of one was from 0 to 02 seconds.
[01:27:14.470] seconds.
[01:27:14.480] seconds. And
[01:27:16.390] And
[01:27:19.669] what it will do
[01:27:27.430] it knows
[01:27:30.950] what timings are for your prompt and
[01:27:34.070] where the lyrics are and what the lyrics
[01:27:37.030] are. Uh, so that's all I did. I copied
[01:27:39.510] it, told it exactly what I wanted to do,
[01:27:41.430] which was just very basic. We've got a
[01:27:43.270] background here of a stage and we've got
[01:27:45.430] a character. I just wanted it to sync. I
[01:27:47.189] wasn't doing anything fancy. It's more
[01:27:50.950] just a an exercise to show it working.
[01:27:53.110] So, it gave me a I sent this in. It gave
[01:27:56.070] me a prompt. Done. Job's done. And then
[01:27:57.830] you just need to copy and paste it into
[01:27:57.840] you just need to copy and paste it into here.
[01:28:00.470] here.
[01:28:02.229] There's no automatic way of actually
[01:28:04.629] putting it in because
[01:28:08.070] your prompt is independent of this. So,
[01:28:10.149] you know, you go into chat GPT or Claude
[01:28:12.950] or whoever, give it those details, it
[01:28:14.470] gives you a prompt, and then I just copy
[01:28:17.189] and pasted it back in here, and as long
[01:28:19.750] as you've got inverted commas where your
[01:28:22.550] dialogue or your singing is, your lyrics
[01:28:24.709] are, it will pop up with ref one, and
[01:28:28.950] you can click it. If it doesn't give you
[01:28:30.870] inverted commas and it gives you the
[01:28:32.870] other version which I always forget what
[01:28:35.270] it's called 66.99
[01:28:38.470] either end it won't show up as ref one.
[01:28:41.830] It has to be this.
[01:28:45.910] Okay. And that is pretty much it. So
[01:28:48.390] this is quite a useful feature basically
[01:28:51.030] I think and it saves a lot of time and a
[01:28:52.870] lot of frustration
[01:28:56.470] and it only works on lip sync mode.
[01:29:02.070] Um, and then you hit run and pray. No,
[01:29:03.830] you hit run and you should get a
[01:29:06.629] generation, uh, which I will show you in
[01:29:09.430] a second. So, just to look on here as
[01:29:13.270] well. So, we've got omni reference,
[01:29:16.790] excuse me. Um, we've got reference and
[01:29:19.990] we're doing this one at 16.9. So, wide
[01:29:28.229] anything you see, I'm probably going to
[01:29:30.950] tidy this bit up a little bit, but any
[01:29:33.910] of this raw latent carry or enable VA
[01:29:33.920] of this raw latent carry or enable VA re-encode,
[01:29:35.669] re-encode,
[01:29:37.910] leave them on. It's It's to do with how
[01:29:41.510] the um, chunk seam works from one to the
[01:29:43.430] next, and it keeps it pretty much
[01:29:43.440] next, and it keeps it pretty much flawless.
[01:29:44.950] flawless.
[01:29:46.629] If you play around with it too much, it
[01:29:49.030] might break it or not work quite as
[01:29:52.149] well. Um, all the samplers I've been
[01:29:57.270] using have been uh Oiler Beta
[01:29:59.510] and on this one I'm doing even though
[01:30:02.070] we're using an eightstep Laura, I'm
[01:30:05.350] doing 10 steps and we're not doing seed
[01:30:07.669] hunt and we're not doing late and only
[01:30:10.310] seed hunt. So, we don't need that. Um,
[01:30:14.070] we do not need prompt override on
[01:30:17.270] shift values leave as they are. And then
[01:30:19.350] we've got the upscaler. So we're doing
[01:30:25.430] six steps on the first pass and
[01:30:28.870] then we are upscaling to 1 megapixel.
[01:30:31.110] So the other four steps will be done on
[01:30:33.510] the second pass.
[01:30:36.229] That's it. That's your settings.
[01:30:40.550] And this video here is what you get.
[01:30:51.510] Okay.
[01:30:54.310] So, it is quite a straightforward one,
[01:30:58.629] but it works really well. And
[01:31:00.310] once you sort of see it, the lip sync
[01:31:07.510] It's really clear.
[01:31:09.510] And like I said, this is a basic prompt,
[01:31:12.629] so you know, you can put your own stamp
[01:31:15.669] on it or do something
[01:31:23.030] I'm not going to
[01:31:25.350] I'll leave it to run for that whole
[01:31:25.360] I'll leave it to run for that whole minute.
[01:31:36.870] inside
[01:31:40.470] your arms.
[01:31:42.870] You walked away
[01:31:51.270] pretty cool.
[01:31:53.590] Okay, so
[01:31:56.629] that's lip sync uh in terms of a music
[01:31:59.990] video lip sync. The next one I'll show
[01:32:08.950] so just for dialogue basically and the
[01:32:11.350] same method should be applied but we'll
[01:32:13.750] do a little test with that as well.
[01:32:16.470] Okay. So, now we're going to do a lip
[01:32:20.550] sync, just a normal um lip sync rather
[01:32:22.950] than a song. So, we're going to use
[01:32:22.960] than a song. So, we're going to use Marilyn.
[01:32:25.270] Marilyn.
[01:32:26.629] There we go. So, we've got a character
[01:32:29.669] sheet for our Marilyn kind of looking
[01:32:29.679] sheet for our Marilyn kind of looking person.
[01:32:31.270] person.
[01:32:34.390] Um, and we've
[01:32:38.870] also got an audio file. Now, this one,
[01:32:40.229] it doesn't obviously it doesn't sound
[01:32:42.229] like Marilyn. It just it's just a
[01:32:44.310] general one that I've got. So, if you
[01:32:44.950] listen to this,
[01:32:46.950] imagine having your own AI version of
[01:32:48.709] you working around the clock, never
[01:32:51.030] sleeping, never stop. It's
[01:32:53.110] what uh Marlin would sound like if she
[01:32:57.110] came from Wiccan. Right. So, let's let's
[01:32:59.830] dive into it. So, it's a 45se second
[01:33:04.950] clip just over. Um, and I've also put
[01:33:08.149] the same one in the
[01:33:10.470] uh audio reference here for whisper,
[01:33:12.149] which it shouldn't be necessary, but
[01:33:14.870] let's just do it anyway. Um, and then
[01:33:16.310] we're just going to try and we're going
[01:33:18.629] to change that to medium and then
[01:33:23.910] So,
[01:33:25.910] again, this might take a few seconds.
[01:33:28.470] So, let me get back to you.
[01:33:30.149] Okay, there we go. So, we've got the
[01:33:32.790] transcribed audio with all the different
[01:33:41.910] apparently Okay. So, let's We'll have to
[01:33:51.350] Okay. So,
[01:33:53.669] we got that. We need to insert it into
[01:33:57.350] timed cuts so that it can populate this.
[01:34:00.550] So if we do that
[01:34:04.149] and bump.
[01:34:09.430] So now we have three chunks and it's
[01:34:12.629] populated the whole thing with the the
[01:34:20.229] Okay.
[01:34:24.149] And down here, we now have all of that
[01:34:27.830] dialogue in the correct timings. So, we
[01:34:30.229] can copy that. And I'm going to paste
[01:34:32.470] this into
[01:34:36.149] Claude and get a prompt. So, bear with
[01:34:39.510] me a second.
[01:34:42.149] Okie do. So,
[01:34:45.430] this is what we've got now.
[01:34:48.950] We've got a prompt, a sound, and the
[01:34:51.990] timeline cuts. So, you notice there will
[01:34:54.149] be some really thin slithery ones, and
[01:35:00.149] this is just between like breaths. So,
[01:35:02.709] um Claude has come up with look short
[01:35:05.669] breath, chin lifting slightly, just tiny
[01:35:07.590] little movements that can be put into
[01:35:11.189] the cuts when there's no dialogue. All
[01:35:14.149] of them are marked with ref one. And
[01:35:16.870] same for the other chunks.
[01:35:19.590] And got ref one there. Don't we've not
[01:35:21.430] put a location in this one. We're
[01:35:23.430] generating that.
[01:35:27.910] And that should be good to go.
[01:35:31.910] And not changed anything on here. So 10
[01:35:34.790] steps again.
[01:35:37.430] Six first pass steps
[01:35:41.430] and the other four in the second pass.
[01:35:41.440] and the other four in the second pass. Um,
[01:35:51.669] one other thing I haven't gone through
[01:35:57.189] yet cuz it's kind of a bit beta tested.
[01:35:57.199] yet cuz it's kind of a bit beta tested. So,
[01:35:58.709] So,
[01:36:07.430] when I was looking at the songs for
[01:36:10.470] doing a music video, if they're like 3
[01:36:14.950] minutes long, and
[01:36:16.870] that's that's quite a lot of chunks. I
[01:36:18.390] think the 3 minute song was something
[01:36:21.750] like 13 chunks. Um,
[01:36:24.950] and that's that's a lot of time. It took
[01:36:29.189] 35 minutes to do a 60-second
[01:36:31.350] video. So it was going to be something
[01:36:34.070] like three hours of constant rendering
[01:36:37.270] to do a three minute song.
[01:36:41.430] So I come up with um a plan for that.
[01:36:44.470] We can this lip basically it's quite
[01:36:46.310] hard to explain the lip sync long form
[01:36:49.669] resume. Basically what it does it saves
[01:36:51.510] your project
[01:36:54.310] as it is now to your computer with
[01:36:56.229] whatever name you give it. That's from
[01:36:59.910] the uh music video one. So you can
[01:37:02.470] create a new one
[01:37:02.480] create a new one and
[01:37:04.790] and
[01:37:04.800] and then
[01:37:09.830] do which however many chunks you want.
[01:37:12.470] So this was set to four cuz we thought
[01:37:15.669] four is a good um number. You know it
[01:37:18.229] takes 35 minutes to run. It's a 1 minute
[01:37:22.470] video. So four chunks is kind of okay.
[01:37:25.270] It's not going to take you forever.
[01:37:27.189] But say for example you wanted to stop
[01:37:29.910] and resume it the next day.
[01:37:33.350] Okay. So normally that would be kind of
[01:37:35.430] impossible. You'd have to start again.
[01:37:38.390] But with this create project it will
[01:37:43.830] save exactly where you are. Um and in
[01:37:46.950] theory the following day say you turn
[01:37:48.629] your computer on again. You say right I
[01:37:51.270] want to continue with that project. you
[01:37:53.830] would change the start chunks
[01:37:58.470] um from to five to eight
[01:38:02.390] and you can select in here
[01:38:04.870] your project and it'll reload the
[01:38:09.990] project up again. It will find the the
[01:38:12.390] cut from one chunk to another so it's
[01:38:16.470] seamless still and it'll resume.
[01:38:18.229] Uh, and that way then you're not having
[01:38:21.669] to do one continuous long generation. It
[01:38:25.030] will do as many as it needs. So you can
[01:38:26.629] you could save it again. You could do
[01:38:29.350] two more chunks, save it again, and it
[01:38:32.310] will pick up from where it left off.
[01:38:35.350] It is beta testing, so
[01:38:37.109] you might have to trial it and see what
[01:38:39.830] happens. But I thought that was a really
[01:38:41.510] good feature.
[01:38:43.109] Uh, and obviously it's got to be ticked
[01:38:45.109] on over here as well, otherwise it does
[01:38:45.119] on over here as well, otherwise it does nothing.
[01:38:46.790] nothing.
[01:38:49.270] Okay, so we're good to go with this. I'm
[01:38:51.189] going to hit run and get back to you
[01:39:00.470] Okay, let's see what we got.
[01:39:02.390] Imagine having your own AI version of
[01:39:04.229] you working around the clock, never
[01:39:06.229] sleeping, never stopping, creating
[01:39:08.149] content, engaging your audience,
[01:39:10.149] building your brand while you focus on
[01:39:12.550] what actually matters. Your own AI twin
[01:39:14.149] could handle the repetitive stuff, the
[01:39:15.990] boring posts, the endless videos, the
[01:39:17.830] comments, the captions, everything you
[01:39:20.070] never have time for. And the crazy thing
[01:39:22.229] is, it looks like you, it sounds like
[01:39:24.229] you, it shows up for your audience every
[01:39:26.550] single day without you lifting a finger.
[01:39:28.709] But here's the thing, what would you
[01:39:30.470] actually do with yours? Would you build
[01:39:32.470] an empire? Launch that side hustle
[01:39:34.390] you've been putting off. Finally have
[01:39:35.990] time for the people that matter. Travel
[01:39:38.070] more, work less. The applications are
[01:39:39.830] endless. And this isn't science fiction
[01:39:41.669] anymore. This is happening right now.
[01:39:43.910] Your AI twin is waiting. So the only
[01:39:52.149] I think it's pretty cool. Um,
[01:39:56.229] so yeah, so that's the lip sync version
[01:40:00.390] and it's pretty accurate and it also is
[01:40:02.629] over three chunks.
[01:40:05.109] Uh, and I didn't see a seam again. So I
[01:40:07.750] think it's a pretty successful run.
[01:40:09.750] Okay. So, the next section we've got is
[01:40:11.590] prompt override.
[01:40:14.070] Uh, so this box here, this text
[01:40:16.950] multi-line box, you can put in a
[01:40:21.109] properly formatted prompt into this and
[01:40:23.990] will override the chunking system here
[01:40:27.750] and output your video. You need to set
[01:40:30.149] the reference mode or first frame mode
[01:40:32.550] up here, total duration, time, and chunk
[01:40:32.560] up here, total duration, time, and chunk size.
[01:40:34.470] size.
[01:40:36.629] um which I would unless you're looking
[01:40:39.109] for smaller chunks I would leave it 15.
[01:40:42.709] Um set all your other settings
[01:40:45.590] and then on here prompt override tick
[01:40:49.350] that to on and it will use this box
[01:40:52.149] instead of the chunking system.
[01:40:54.629] the it does still need you do need still
[01:40:56.629] still need to add your reference into
[01:40:59.669] here and then click the analyze button
[01:41:02.790] which will bring up the character
[01:41:02.800] which will bring up the character um
[01:41:07.510] and if you have a look here I've given
[01:41:09.430] you some tips
[01:41:12.229] so if you have a look here this tells
[01:41:13.910] you exactly what you need to do in the
[01:41:16.550] format and the template so you can post
[01:41:19.270] that paste that into your LLM if needed
[01:41:21.750] and they should be able to update your
[01:41:24.310] current prompt to that and then you just
[01:41:26.550] paste it into
[01:41:28.550] the box.
[01:41:31.350] Uh if you want to try one out, this is
[01:41:34.070] uh one of my examples.
[01:41:37.669] So you can
[01:41:39.510] you probably need to change this first
[01:41:42.470] bit, the subject definition. So it's the
[01:41:44.470] slender woman with the blue bob hair.
[01:41:45.669] Otherwise, your character's going to
[01:41:48.229] change to that. So when you click your
[01:41:52.149] analyze button down here, it'll give you
[01:41:52.159] analyze button down here, it'll give you this.
[01:41:53.669] this.
[01:41:55.669] And this is exactly what needs to append
[01:41:57.990] to here.
[01:41:59.590] So if you've got a different character,
[01:42:01.430] you click analyze. Whatever pops up
[01:42:01.440] you click analyze. Whatever pops up here,
[01:42:03.510] here,
[01:42:06.950] swap it into here. And then if you want
[01:42:10.229] to try it out,
[01:42:18.629] Pop that into there and click run. And
[01:42:22.149] that'll give you that'll run the actual
[01:42:24.870] video and you'll get a an example of
[01:42:26.790] that afterwards.
[01:42:29.590] Anytime we do any of these different
[01:42:32.229] Oops. Anytime we do any of these
[01:42:35.270] different videos, the always outputs
[01:42:35.280] different videos, the always outputs the
[01:42:37.030] the
[01:42:40.070] compiled prompt here. I've not got one
[01:42:41.910] there to show you. So, it's not got one,
[01:42:43.350] but that's where it'll show you the
[01:43:00.310] and and
[01:43:02.709] okay. So
[01:43:05.270] now if you want to do multiple chunks
[01:43:08.550] then you have this version. So it
[01:43:10.709] explains it here,
[01:43:12.950] but basically it's been designed so that
[01:43:15.270] when you prompt it like this, you can do
[01:43:17.590] multiple chunks. So you can see there
[01:43:19.270] you've got chunk one, which is the
[01:43:24.629] and then you've got chunk two. So it's
[01:43:27.189] basically like a an extension, but it
[01:43:28.950] just shows you how to put it all
[01:43:30.950] together. And in the same way, if we
[01:43:33.830] wanted to, we could just plug that into
[01:43:36.550] there. As long as we've still appended
[01:43:38.790] this subject,
[01:43:43.270] then that one will run as well.
[01:43:45.109] So, and then we've done the same for
[01:43:48.149] first frame, last frame. So, you can use
[01:43:50.629] this in the same manner.
[01:43:52.550] Um, same sort of thing again. So,
[01:43:55.030] there's a template here. If you pass
[01:43:58.149] that in to your LLM, they should be able
[01:44:00.550] to give you a prompt that looks like
[01:44:00.560] to give you a prompt that looks like this.
[01:44:03.030] this.
[01:44:03.040] this. Um,
[01:44:05.430] Um,
[01:44:07.189] two things with the first frame last
[01:44:10.229] frame, which we've already gone through,
[01:44:12.709] but if you only put when you're on first
[01:44:14.550] frame, last frame mode, it'll have two
[01:44:14.560] frame, last frame mode, it'll have two boxes.
[01:44:16.390] boxes.
[01:44:18.070] And as you probably already know from
[01:44:20.550] other people's videos, the first frame
[01:44:23.430] last frame mode is bas basically video
[01:44:25.109] generation of any kind. If you put no
[01:44:27.590] reference images in, it's just going to
[01:44:29.590] generate a video from your prompt. If
[01:44:31.590] you put a first frame image in, it'll
[01:44:33.830] start from the first frame and move on
[01:44:36.390] from that. If you put both in, it'll do
[01:44:38.310] first frame, last frame. So, obviously,
[01:44:40.629] your frame isn't going to be a grid
[01:44:42.390] reference like this. It's going to be to
[01:44:45.430] first frame. And then your second one in
[01:44:46.790] the other box is going to be the last
[01:44:46.800] the other box is going to be the last frame.
[01:44:53.109] Yeah. Let's just switch it for a second
[01:44:56.790] so you can see it again.
[01:44:58.709] There we go. So there's two boxes. First
[01:45:02.629] frame, last frame. Drop them in those.
[01:45:05.510] And then use these templates for the
[01:45:08.950] first frame. Last frame.
[01:45:11.590] I hope that makes some sense.
[01:45:13.430] I know it's probably quite confusing,
[01:45:15.990] but to be honest, if you look through
[01:45:17.990] the examples from the video, you should
[01:45:20.149] see what I mean.
[01:45:22.070] And we've got lots of examples there to
[01:45:27.910] And I'm going to pop that back to there.
[01:45:31.189] So, we have just had a render example
[01:45:36.629] finished. So, I just used this prompt
[01:45:39.750] exactly from this string with my
[01:45:39.760] exactly from this string with my reference.
[01:45:41.590] reference.
[01:45:45.189] Um, and it's just completed, which is
[01:45:53.350] So, this one is the
[01:45:56.790] uh 30 second two chunks
[01:45:59.430] and it's come from the prompt override,
[01:46:15.590] and I think that works pretty well.
[01:46:17.750] Sealing it now. Hold on.
[01:46:20.390] That is prompt override
[01:46:22.310] in a nutshell.
[01:46:25.189] Um again,
[01:46:27.669] um feel free to message me. Um if you
[01:46:29.270] want to chat to me rather than pop
[01:46:30.950] things in the comments, just follow my
[01:46:33.430] school community. At the moment is free
[01:46:35.189] to join and once you're in there, just
[01:46:38.310] message me on it. Um
[01:46:39.910] it's not some weird way of getting you
[01:46:42.390] to add yourself to my school community.
[01:46:43.990] If you want to if you want to go in
[01:46:45.750] there, ask me a question, then pop out
[01:46:48.070] again, you can. There's you're not
[01:46:50.149] committed to stay in it. It's just
[01:46:52.229] literally I don't want a million
[01:46:54.310] different platforms and people messaging
[01:46:56.229] me on all of them. I'd rather have just
[01:46:58.149] had one central place for people to
[01:47:02.229] message me. Uh other than that, that's
[01:47:04.229] that one for now and I'll get back to
[01:47:06.629] you in the next bit.
[01:47:11.189] Okay, so moving on. Um I really should
[01:47:12.550] have just made this into a load of
[01:47:15.750] separate videos, but
[01:47:18.229] um video reference. So, we've talked
[01:47:20.070] about lip sync, we've talked about first
[01:47:22.950] frame, last frame, uh, reference
[01:47:25.590] chunking. Uh, one of the only things we
[01:47:29.109] haven't gone through is reference video.
[01:47:31.270] So, this can be a bit of a tricky one,
[01:47:33.189] and it,
[01:47:35.669] uh, tripped me up a little bit, to be
[01:47:39.109] fair. So, at the bottom here, we've got
[01:47:41.270] the reference videos. And, as you know,
[01:47:43.030] with a reference video, you can do
[01:47:46.390] multiple things. So you can edit it, you
[01:47:49.590] can change a character in it, you can uh
[01:47:51.590] extend it. So there's a few different
[01:47:53.750] things we'll look at. One of the basic
[01:47:59.510] things was uh motion transfer. Now
[01:48:03.270] it's not 100% um has to be said with
[01:48:08.070] Miniax H3. It's not like scale or um one
[01:48:10.310] anime in the sense that it's pretty much
[01:48:12.149] a onetoone.
[01:48:15.270] Uh, even with Control Net, it's not
[01:48:15.280] Uh, even with Control Net, it's not perfect,
[01:48:16.870] perfect,
[01:48:19.590] but it is pretty good. But the thing
[01:48:21.350] that might trip people up, and this
[01:48:24.470] tripped me up with it, was things like
[01:48:28.870] the reference video. So, I've put in
[01:48:32.550] this one. So, we've got the Dead
[01:48:35.750] uh video, and
[01:48:38.629] it tripped me up because
[01:48:40.629] the frame rate on the video I downloaded
[01:48:43.350] was 60 frames or 30 frames pers and
[01:48:47.430] obviously minimax is 24. Um, so there
[01:48:50.390] was a couple of things in there that I
[01:48:53.510] couldn't work out why the dance didn't
[01:48:56.870] go the whole length of the 15 seconds.
[01:48:59.590] Uh, but now we know it was that you've
[01:49:02.310] got to basically Well, to be fair, if
[01:49:03.430] you're using the node, you don't need to
[01:49:05.510] do anything because I've already fixed
[01:49:08.149] it. So, whatever video you put in here,
[01:49:10.870] it'll fix it so that it's the correct uh
[01:49:10.880] it'll fix it so that it's the correct uh FPS.
[01:49:12.790] FPS.
[01:49:14.149] But, let's have a look at the options.
[01:49:15.430] So, we're going to basically just going
[01:49:18.790] to try and replicate the dance. And as I
[01:49:20.629] said, it isn't perfect, but it's pretty
[01:49:23.750] good. Um, we've got another set in
[01:49:27.430] setout timer. And
[01:49:29.430] so that means basically if you've got a
[01:49:31.270] longer video, I mean this is only 23
[01:49:33.030] seconds. Uh but if you've got a longer
[01:49:35.830] video, minute, 2 minutes, you can choose
[01:49:37.750] at what point you want it to start and
[01:49:40.310] what point you want it to finish. Uh if
[01:49:42.149] you want to capture a particular motion,
[01:49:43.830] it might not be a dance. It might just
[01:49:47.270] be uh a camera movement
[01:49:50.470] uh or just a way that a character moves.
[01:49:52.310] Um but I'm going to do we're going to do
[01:49:55.350] two things. I'm going to do 10 seconds
[01:49:58.870] uh 15 seconds first.
[01:49:58.880] uh 15 seconds first. And
[01:50:00.709] And
[01:50:02.550] so there's a couple of different options
[01:50:05.830] here. So we want
[01:50:08.149] uh editing source
[01:50:09.750] and we don't want weak reference. We
[01:50:11.510] want duplicate the video, replace the
[01:50:11.520] want duplicate the video, replace the character.
[01:50:13.510] character.
[01:50:17.830] And we also want the audio
[01:50:20.070] which I need to sort something out. So
[01:50:23.350] basically you can
[01:50:25.990] You can have it try to take the clip's
[01:50:29.189] audio so that you're replacing the
[01:50:32.149] person potentially the background
[01:50:36.070] um and it's passing through the audio
[01:50:43.590] this is what we'll do after this test.
[01:50:48.550] So, I have made it work whereby it will
[01:50:51.830] seamlessly join between chunks similar
[01:50:54.629] to the other videos we've done. So, 15
[01:50:57.270] seconds is kind of the cut off point for
[01:51:00.709] one chunk. If your video is longer than
[01:51:05.350] that, if you click this, you can insert
[01:51:08.229] it into the chunks and it will open
[01:51:10.950] enough chunks for it to fill whatever
[01:51:13.590] time is. So, if this was 60 seconds,
[01:51:16.390] it'd open for three more chunks. So,
[01:51:18.709] you'd be able to do a 60-second video,
[01:51:22.229] and it should seamlessly transition.
[01:51:24.470] We don't need that for this test. And we
[01:51:26.310] don't need to insert anything on this
[01:51:35.430] just bear with me a second, though.
[01:51:37.030] Okay. Sorry, I just had to change
[01:51:38.870] something there. So when you tick this
[01:51:42.709] box, audio state should appear and it's
[01:51:45.030] got a couple of different options here.
[01:51:47.430] If you wanted to reuse it exactly rather
[01:51:49.430] than reference it, you should click this
[01:51:52.950] one. Now again,
[01:51:55.030] this is kind of a work in progress. It
[01:51:56.950] did work a couple of times, but it isn't
[01:51:56.960] did work a couple of times, but it isn't perfect.
[01:51:58.470] perfect.
[01:52:02.070] Um, I could change it, but I'm not going
[01:52:04.470] to change it right now because it's
[01:52:07.030] something that
[01:52:10.070] needs to be done under the hood
[01:52:10.080] needs to be done under the hood potentially.
[01:52:16.229] Okay, so we've got that set. We've got a
[01:52:18.709] background. We've got a character.
[01:52:27.830] which we don't need. So, we're going to
[01:52:30.229] drop this down to 15
[01:52:33.669] like this. I'll get rid of one of them.
[01:52:35.189] And we've got a prompt. And I've kept
[01:52:37.350] the prompt quite simple. Uh there's
[01:52:39.109] probably more you can do. You don't need
[01:52:46.709] So, I haven't put anything in obviously
[01:52:49.910] soundscape or diioetic music. Um and
[01:52:51.350] I've not put anything in style. I'm
[01:52:53.350] pretty sure you probably can. Uh you
[01:52:54.790] probably add more to the core. You can't
[01:52:56.149] really I wouldn't put anything in the
[01:52:59.189] musiccape unless you're actually not
[01:53:03.990] using the audio track um at all.
[01:53:07.990] Um yeah. Okay. So, let's run this and
[01:53:09.830] see where we get. Most of the other
[01:53:11.510] settings I've kept to the things I've
[01:53:14.870] kept them to before. So, 0.5
[01:53:18.709] uh two-stage sampling, six first steps,
[01:53:21.030] uh four last steps.
[01:53:23.830] and we're on reference model 15-second
[01:53:27.270] and chunk. So, we're going to run it and
[01:53:29.270] let's have a look at what the output is
[01:53:29.280] let's have a look at what the output is shortly.
[01:53:37.910] Okay. And we can see here in the preview
[01:53:41.030] that it's definitely starting to do the
[01:53:42.790] right movements and we've got the right
[01:53:45.350] character and background. So, we'll
[01:53:48.470] continue and see how that goes. I will
[01:53:51.189] say as well that it does take longer
[01:53:53.189] from what I can see to generate from a
[01:53:55.910] video. Um,
[01:53:58.070] yeah, it's obviously it's got to read
[01:54:00.470] the video I suppose when it's doing it.
[01:54:02.310] But yeah, you need to bear that in mind
[01:54:11.669] Okie do. So, this is our output
[01:54:13.990] and it's not bad.
[01:54:15.830] I'm not going to say it's perfect cuz I
[01:54:17.990] don't think she's dancing exactly the
[01:54:22.149] same. Uh let's have a look.
[01:54:23.750] Let's bring the reference in again and
[01:54:40.229] So it is more using it as a loose
[01:54:42.229] reference rather than mimicking it one
[01:54:45.109] to one. Um
[01:54:46.870] and I have tried control net with this
[01:54:49.270] as well. I didn't find it made it much
[01:54:49.280] as well. I didn't find it made it much better.
[01:54:51.189] better.
[01:55:02.790] yeah, it does have the audio. So the
[01:55:05.589] audio pushed through um and very minimal
[01:55:07.990] prompting as well. Uh, I'm sure you
[01:55:10.870] could do more to it. Uh, this is more
[01:55:13.830] just about the settings and how to set
[01:55:17.030] it. But imagine if you try in your cuts,
[01:55:20.149] you could add um,
[01:55:22.629] you know, different camera movements in
[01:55:25.350] each cut so that they maybe get a zoom
[01:55:28.070] in on some or try and orbit around on
[01:55:31.030] another. Uh, I'll be trying that and I
[01:55:32.790] will probably make a separate video for
[01:55:36.149] this at some point. Um, but yeah, for
[01:55:38.870] now that works really well.
[01:55:45.430] And I'm going to do another video. I'm
[01:55:47.589] going to do another one now using a
[01:55:49.350] different reference. So, we'll use the
[01:55:51.030] same character,
[01:55:53.589] but we're going to take this one out.
[01:55:57.030] And there's a reference from one of the
[01:56:00.550] online uh official sites. So, we'll use
[01:56:03.189] this dance instead. And we're going to
[01:56:05.030] set this.
[01:56:07.750] Actually, this one is only 9 seconds.
[01:56:09.830] So, it might be this might not be worth
[01:56:14.229] it. Um, okay. So,
[01:56:17.910] okay. I might have to change that again.
[01:56:20.149] Right. Let's go back to where we were
[01:56:22.550] then. Really, it's just for the example
[01:56:25.030] of the chunking. So, we'll use what we
[01:56:30.709] had. And if we put 24 seconds on this,
[01:56:32.470] there we go.
[01:56:32.480] there we go. So
[01:56:34.310] So
[01:56:36.229] add one chunk. Yeah. So we're going to
[01:56:38.390] use the music again.
[01:56:41.350] Going to use editing and we're going to
[01:56:43.669] duplicate the video and we're going to
[01:56:51.910] So if we insert the chunk,
[01:56:54.470] we now have two chunks.
[01:56:54.480] we now have two chunks. So
[01:56:56.390] So
[01:56:58.550] and also as well, we just need to change
[01:57:01.990] that. So, change that to 24 as well,
[01:57:04.149] just to make sure.
[01:57:08.470] Now, when we do it, it's going to
[01:57:10.550] do the first 15 seconds in this first
[01:57:12.629] chunk and continue the rest of it in
[01:57:14.550] this second chunk, and it should
[01:57:18.709] seamlessly give us the full 24 seconds.
[01:57:21.350] So, let's just double check. We got the
[01:57:23.109] music on. Yeah, we've got the
[01:57:25.350] continuation on.
[01:57:27.830] Uh, fully preserved. Something else as
[01:57:29.189] well that you really need to make sure
[01:57:31.990] you do, and I may or may not have
[01:57:34.870] mentioned this before, probably have.
[01:57:37.589] Make sure you do the analyze on here and
[01:57:41.589] here because this is what
[01:57:44.709] identifies the different objects.
[01:57:47.109] So, I think we did it in a previous one.
[01:57:49.669] We didn't have the cap and we had to
[01:57:52.790] reanalyze it again. The background, I'd
[01:57:54.310] forgotten to do it on one of the
[01:57:56.870] previous tests, so this was blank.
[01:58:00.390] And basically all it did was add my
[01:58:02.390] character to this background, which
[01:58:05.109] isn't a bad thing. Obviously, you know,
[01:58:06.790] if you want to just replace a character
[01:58:09.030] in a particular scene that's already
[01:58:11.350] existing, then that's the way to do it.
[01:58:13.750] Get rid of the location, just use your
[01:58:16.470] character and it will replace the
[01:58:16.480] character and it will replace the character.
[01:58:18.870] character.
[01:58:20.229] Okay, so we're going to run this one
[01:58:26.070] again. Um, that last one just
[01:58:29.510] Just so you can see, it took 16 minutes.
[01:58:33.270] So, yeah, 15 seconds, 16 minutes for
[01:58:35.910] that first dance part.
[01:58:37.350] Right, I'm going to run it again and get
[01:59:04.470] And I definitely can't see a scene.
[01:59:06.390] I don't know if you can, but I didn't. I
[01:59:08.950] missed it if it was there.
[01:59:11.910] Back to the beginning again.
[01:59:14.390] So, I think that is a pretty solid
[01:59:17.030] performance. I can I can't guarantee
[01:59:20.629] it's exactly the same moves, but it's a
[01:59:22.310] pretty good motion transfer. It's a good
[01:59:26.149] dance. Um, yeah. Okay. So, the next
[01:59:29.270] thing we're going to attempt to do is
[01:59:32.709] um add a character to an existing scene.
[01:59:32.719] um add a character to an existing scene. Now,
[01:59:34.229] Now,
[01:59:36.470] fair warning, I haven't done that
[01:59:40.550] before, so let's see how that works.
[01:59:43.109] Okie do. So,
[01:59:46.310] I'm really impressed with this. Um,
[01:59:49.189] so we've tried
[01:59:51.990] adding a
[01:59:56.310] a scene from an old sci-fi series, Space
[01:59:56.320] a scene from an old sci-fi series, Space 1999,
[01:59:58.550] 1999,
[02:00:03.030] and we've added an extra character,
[02:00:06.629] and we've added dialogue between two
[02:00:08.950] characters and extended the scene
[02:00:12.229] slightly. Uh, and I think it works
[02:00:15.830] really well. Um, okay. So, let me run
[02:00:18.550] you through what we did. So, we got our
[02:00:21.910] blue head character and we went with
[02:00:25.510] Chat GPT. We took a screenshot of the
[02:00:28.390] character on the right here and asked
[02:00:31.510] Chat GPT to do a grid reference with
[02:00:33.910] this woman with the same outfit or
[02:00:36.550] similar outfit. Um, and then we've
[02:00:41.030] analyzed each of those two images. Um,
[02:00:44.149] so the reason we put this character in
[02:00:47.270] reference 2 is so that we could clone
[02:00:50.390] his voice. Now, the clone voice is not
[02:00:53.830] quite perfect to be fair, but that's the
[02:00:57.830] reason he's in there. Um,
[02:00:57.840] reason he's in there. Um, and
[02:00:59.830] and
[02:01:01.910] okay, so
[02:01:04.470] uh I will show you the original
[02:01:05.669] Eagle one to Alpha.
[02:01:06.870] Go ahead. One
[02:01:08.950] liftoff complete. Trajectory computed
[02:01:11.510] and programmed. I will be in orbit in
[02:01:13.589] four minutes.
[02:01:17.589] Okay, so that's the original video. Um,
[02:01:21.750] and what we're doing is we
[02:01:24.070] are going to have this young lady walk
[02:01:27.910] through the door that's near the pilot,
[02:01:31.830] sit down in the other seat opp uh next
[02:01:35.830] to the pilot and she turns to him after
[02:01:39.350] he's finished talking and says, "Are you
[02:01:41.510] sureing how to fly this thing?" And he
[02:01:43.109] turns back to her and says, "I hope so."
[02:01:48.149] Or something similar. Um, to do this,
[02:01:50.709] we've used reference video.
[02:01:53.830] I've set an in and-out time as to where
[02:01:56.470] I want it, which is when he's sat in the
[02:01:59.109] cockpit. So, ignore ignore this bit. It
[02:02:01.910] was a few seconds before the cockpit
[02:02:01.920] was a few seconds before the cockpit scene.
[02:02:03.430] scene.
[02:02:07.109] Um, we've included the audios, uh, the
[02:02:10.470] clips audio and we've done it as an
[02:02:14.229] editing source fully preserved because
[02:02:17.510] we want the whole scene preserved. And
[02:02:20.149] the audio state, we've reused it exactly
[02:02:22.229] as it was.
[02:02:24.390] Um, we don't need to continue with
[02:02:27.030] chunks on this one particularly, even
[02:02:29.109] though we've added an extra chunk.
[02:02:32.310] That's more for if the dialogue of the
[02:02:35.990] video goes over 15 seconds.
[02:02:36.000] video goes over 15 seconds. Um,
[02:02:38.310] Um,
[02:02:40.709] we didn't need to do this either because
[02:02:42.390] the dialogue doesn't go over the 15
[02:02:42.400] the dialogue doesn't go over the 15 seconds.
[02:02:44.310] seconds.
[02:02:49.510] Um, I've added a new toggle in the video
[02:02:52.070] reference which is analyze the first
[02:02:56.550] frame. So whatever your set in value is,
[02:02:59.030] if you click analyze, it'll normally
[02:03:01.510] says analyze first frame. So if you
[02:03:05.270] click the analyze first frame, it
[02:03:07.910] does the same thing as it does when you
[02:03:10.950] hit analyze here,
[02:03:14.390] it'll analyze the actual first frame and
[02:03:16.790] add that context
[02:03:21.430] to the final prompt. So interior of
[02:03:24.310] spaceship etc. which is basically just
[02:03:27.030] helps the model have context as to what
[02:03:33.030] So it basically
[02:03:35.189] knows where to direct the character to
[02:03:38.070] if that makes sense.
[02:03:38.080] if that makes sense. Um,
[02:03:40.629] Um,
[02:03:40.639] Um, then
[02:03:47.910] what we wanted to do was try and clone
[02:03:51.189] the original character's voice. Now, it
[02:03:53.510] wasn't perfect, so might have to play
[02:03:56.950] with this. We did try this on lip sync,
[02:03:56.960] with this. We did try this on lip sync, but
[02:03:59.030] but
[02:04:02.390] it didn't let you then add the extra
[02:04:05.350] dialogue. it just took over completely
[02:04:09.589] using the original tracks full audio. So
[02:04:12.550] we went with partial partial voice match
[02:04:12.560] we went with partial partial voice match instead.
[02:04:15.430] instead.
[02:04:17.830] But to get that we had to start with lip
[02:04:17.840] But to get that we had to start with lip sync.
[02:04:19.589] sync.
[02:04:28.550] and we uh transcribed it
[02:04:30.870] as we did in the lip sync portion of
[02:04:32.550] this video.
[02:04:35.270] Um, and then we inserted it into timed
[02:04:38.229] cuts. You can see here.
[02:04:41.030] And then I copied that, gave it to
[02:04:43.750] Claude, and he built the prompt around
[02:04:46.709] it. Then
[02:04:49.189] as cuz once you've inserted it into time
[02:04:51.910] cuts, it stays there. So then we went
[02:04:53.990] back to partial voice match to get the
[02:04:57.189] voice match better and not have the
[02:04:59.430] original audio overwhelm the whole
[02:04:59.440] original audio overwhelm the whole scene.
[02:05:01.910] scene.
[02:05:04.709] And because we've got him in reference
[02:05:08.629] to, when we get to the prompt, we have
[02:05:11.189] two boxes because we've got a character
[02:05:15.030] in reference to. So, we can choose who's
[02:05:18.390] saying the lines and
[02:05:20.390] of most of the lines are basically him
[02:05:23.910] cuz it's from the original track. uh at
[02:05:27.830] the end of the first chunk
[02:05:30.149] um when we've got the lady in blue
[02:05:32.310] sitting down.
[02:05:34.550] So this what's quite amazing I find
[02:05:37.030] amazing about this is we've got the
[02:05:41.109] original movement and the original video
[02:05:44.149] and then we're able to prompt over the
[02:05:45.910] top of that. So, while all this is
[02:05:48.870] happening, the lady in blue comes
[02:05:51.750] through the door and then sits down on a
[02:05:57.589] seat and then we've timed it so that the
[02:05:59.350] um original characters finish saying
[02:06:02.310] what he says in the video and then the
[02:06:06.629] bluead girl says her line. It chunks it
[02:06:10.070] go it spills over into chunk two for an
[02:06:12.149] extra 5 seconds.
[02:06:15.030] And then the original character, the guy
[02:06:17.830] says his extra line.
[02:06:20.550] And it's pretty amazing. I've got to be
[02:06:23.350] honest. Um,
[02:06:25.030] this particular one is slightly lower
[02:06:28.070] quality because I wanted to do get it a
[02:06:31.189] bit quicker. So, I just did it on 0.5
[02:06:34.870] and at the time I had it on single stage
[02:06:37.189] sampling, not two-stage. You could do
[02:06:40.149] onto stage sampling, but the test I did
[02:06:42.470] earlier with this 20 seconds took about
[02:06:44.950] half an hour and this is it probably
[02:06:47.350] took about half the time.
[02:06:54.470] Eagle one to Alpha. Go ahead. Liftoff
[02:06:56.149] complete. Trajectory computed and
[02:06:58.709] programmed. I will be in orbit in 4
[02:06:58.719] programmed. I will be in orbit in 4 minutes.
[02:07:07.589] Are you sure you know how to fly this?
[02:07:09.750] I hope so. Otherwise, this will be a
[02:07:11.430] short trip.
[02:07:14.470] I think it's amazing. Honestly,
[02:07:16.709] everything looks
[02:07:20.550] as it should. You barely tell that he's
[02:07:23.669] she's not part of the original
[02:07:25.910] lighting, everything.
[02:07:29.189] Um, and that's
[02:07:30.950] that's probably one of my favorite ones
[02:07:33.109] to do on this. It's amazing. I've got a
[02:07:35.270] load of other things planned for it now.
[02:07:37.589] Um, but that's pretty much all the
[02:07:39.270] reference video stuff that we're going
[02:07:41.830] to do through this. There are other
[02:07:43.430] things and if you look on other
[02:07:44.790] communities online, you're going to find
[02:07:48.550] tons of different ideas. Um, if anybody
[02:07:51.109] wants me to, I will do a separate video
[02:07:55.350] on on this on reference video. um and
[02:07:57.270] maybe dig in a little deeper to it and
[02:08:00.470] try some more complicated bits. But in
[02:08:03.589] terms of the way that this updated node
[02:08:07.750] works, I think that works really well.
[02:08:11.669] And that is pretty much it.
[02:08:13.669] This is going to be a very long video. I
[02:08:17.109] apologize, but um there was a lot of
[02:08:20.390] things to go through and
[02:08:22.950] I basically built a lot of them as I was
[02:08:26.390] fixing them. So yeah, apologies for the
[02:08:28.550] length of the video, but I'm hoping you
[02:08:31.990] find this really useful. Obviously, if
[02:08:34.229] you come up and if with any other things
[02:08:37.669] that any bugs or any other errors, let
[02:08:40.149] me know. I'm happy to try and fix it in
[02:08:42.950] this one. Um, but I think this is a
[02:08:45.910] really useful tool for anybody wanting
[02:08:48.550] to play around with the
[02:08:51.510] H3 Miniax model.
[02:08:54.709] Uh, until the next node,
