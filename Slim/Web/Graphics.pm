package Slim::Web::Graphics;

use strict;

use Scalar::Util qw(blessed);

use Slim::Utils::Misc;

sub processCoverArtRequest {
	#TODO: memoize thumb resizing, if necessary 

	my ($client, $path) = @_;

	my ($body, $mtime, $inode, $size, $contentType); 

	$path =~ /music\/(\w+)\/(cover|thumb)(?:_(X|\d+)x(X|\d+))?(?:_([sSfFpc]))?(?:_([\da-fA-F]{6,8}))?\.jpg$/;

	my $trackid = $1;
	my $image = $2;
	my $requestedWidth = $3; # it's ok if it didn't match and we get undef
	my $requestedHeight = $4; # it's ok if it didn't match and we get undef
	my $resizeMode = $5; # stretch, pad or crop
	my $requestedBackColour = defined($6) ? hex $6 : 0x7FFFFFFF; # bg color used when padding

	# It a size is specified then default to stretch, else default to squash
	if ($resizeMode eq "f") {
		$resizeMode = "fitstretch";
	}elsif ($resizeMode eq "F") {
		$resizeMode = "fitsquash"
	}elsif ($resizeMode eq "p") {
		$resizeMode = "pad";
	} elsif ($resizeMode eq "c") {
		$resizeMode = "crop";
	} elsif ($resizeMode eq "S") {
		$resizeMode = "squash";
	} elsif ($resizeMode eq "s" || $requestedWidth) {
		$resizeMode = "stretch";
	} else {
		$resizeMode = "squash";
	}

	my ($obj, $imageData);

	my $ds = Slim::Music::Info::getCurrentDataStore();

	if ($trackid eq "current" && defined $client) {

		# If the object doesn't have any cover art - fall
		# through to the generic cover image.
		$obj  = $ds->objectForUrl(Slim::Utils::Misc::fileURLFromPath(
			Slim::Player::Playlist::song($client)
		));

	} else {

		$obj = $ds->objectForId('track', $trackid);
	}

	$::d_http && msg("Cover Art asking for: $image" . 
		($requestedWidth ? (" at size " . $requestedWidth . "x" . $requestedHeight) : "") . "\n");

	if (blessed($obj) && $obj->can('coverArt')) {
		$::d_http && msg("can CoverArt\n");
		($imageData, $contentType, $mtime) = $obj->coverArt($image);
	}

	if (!defined($imageData)) {
		($body, $mtime, $inode, $size) = Slim::Web::HTTP::getStaticContent("html/images/cover.png");
		$contentType = "image/png";
		$imageData = $$body;
	}

	$::d_http && msg("got cover art image $contentType of ". length($imageData) . " bytes\n");
	

	if (serverResizesArt()){
		# If this is a thumb, a size has been given, or this is a png and the background color isn't 100% transparent
		# then the overhead of loading the image with GD is necessary.  Otherwise, the original content
		# can be passed straight through.
		if ($image eq "thumb" || $requestedWidth || ($contentType eq "image/png" && ($requestedBackColour >> 24) != 0x7F)) {
			GD::Image->trueColor(1);
			my $origImage = GD::Image->new($imageData);

			if ($origImage) {
				# deterime the size and of type image to be returned
				my $returnedWidth;
				my $returnedHeight;
				my ($returnedType) = $contentType =~ /\/(\w+)/;

				# if an X is supplied for the width (height) then the returned image's width (height)
				# is chosen to maintain the aspect ratio of the original.  This only makes sense with 
				# a resize mode of 'stretch' or 'squash'
				if ($requestedWidth eq "X") {
					if ($requestedHeight eq "X") {
						$returnedWidth = $origImage->width;
						$returnedHeight = $origImage->height;
					}else{
						$returnedWidth = $origImage->width / $origImage->height * $requestedHeight;
						$returnedHeight = $requestedHeight;
					}
				}elsif($requestedHeight eq "X"){
					$returnedWidth =  $requestedWidth;
					$returnedHeight =  $origImage->height / $origImage->width * $requestedWidth;
				}else{
					if ($image eq "cover") {
						$returnedWidth = $requestedWidth || $origImage->width;
						$returnedHeight = $requestedHeight || $origImage->height;
					}else{
						$returnedWidth = $requestedWidth || Slim::Utils::Prefs::get('thumbSize') || 100;
						$returnedHeight = $requestedHeight || Slim::Utils::Prefs::get('thumbSize') || 100;
					}
					if ($resizeMode =~ /^fit/) {
						my @r = getResizeCoords($origImage->width, $origImage->height, $returnedWidth, $returnedHeight);
						($returnedWidth, $returnedHeight) = ($r[2], $r[3]);
					}
				}

				# if the image is a png, it still needs to be processed in case it has an alpha channel
				# hence, if we're squashing the image, the size of the returned image needs to be corrected
				if ($resizeMode =~ /squash$/ && $returnedWidth > $origImage->width && $returnedHeight > $origImage->height) {
					$returnedWidth = $origImage->width;
					$returnedHeight = $origImage->height;
				}

				# the image needs to be processed if the sizes differ, or the image is a png
				if ($contentType eq "image/png" || $returnedWidth != $origImage->width || $returnedHeight != $origImage->height) {

					$::d_http && msg("resizing from " . $origImage->width . "x" . $origImage->height . " to " 
						 . $returnedWidth . "x" . $returnedHeight ." using " . $resizeMode . "\n");

					# determine source and destination upper left corner and width / height
					my ($sourceX, $sourceY, $sourceWidth, $sourceHeight);
					my ($destX, $destY, $destWidth, $destHeight);

					if ($resizeMode =~ /(stretch|squash)$/) {
						$sourceX = 0; $sourceY = 0;
						$sourceWidth = $origImage->width; $sourceHeight = $origImage->height;

						$destX = 0; $destY = 0;
						$destWidth = $returnedWidth; $destHeight = $returnedHeight;
					}elsif ($resizeMode eq "pad") {
						$sourceX = 0; $sourceY = 0;
						$sourceWidth = $origImage->width; $sourceHeight = $origImage->height;

						($destX, $destY, $destWidth, $destHeight) = 
							getResizeCoords($origImage->width, $origImage->height, $returnedWidth, $returnedHeight);
					}elsif ($resizeMode eq "crop") {
						$destX = 0; $destY = 0;
						$destWidth = $returnedWidth; $destHeight = $returnedHeight;

						($sourceX, $sourceY, $sourceWidth, $sourceHeight) = 
							getResizeCoords($returnedWidth, $returnedHeight, $origImage->width, $origImage->height);
					}

					my $newImage = GD::Image->new($returnedWidth, $returnedHeight);

					$newImage->alphaBlending(0);
					$newImage->filledRectangle(0, 0, $returnedWidth, $returnedHeight, $requestedBackColour);

					$newImage->alphaBlending(1);
					$newImage->copyResampled($origImage,
						$destX, $destY,
						$sourceX, $sourceY,
						$destWidth, $destHeight,
						$sourceWidth, $sourceHeight);

					my $newImageData;

					# if the source image was a png and GD can output png data
					# then return a png, else return a jpg
					if ($returnedType eq "png" && GD::Image->can('png')) {
						$newImage->saveAlpha(1);
						$newImageData = $newImage->png;
						$contentType = 'image/png';
					}else{
						$newImageData = $newImage->jpeg;
						$contentType = 'image/jpeg';
					}

					$::d_http && msg("outputting cover art image $contentType of ". length($newImageData) . " bytes\n");
					$body = \$newImageData;
				}else{
					$::d_http && msg("not resizing\n");
					$body = \$imageData;
				}
			}else{
				$::d_http && msg("GD wouldn't create image object\n");
				$body = \$imageData;
			}
		}else{
			$::d_http && msg("no need to process image\n");
			$body = \$imageData;
		}
	}else{
		$::d_http && msg("can't use GD\n");
		$body = \$imageData;
	}

	return ($body, $mtime, $inode, $size, $contentType);
}

{
	#art resizing support by using GD, requires JPEG support built in
	my $canUseGD = eval {
		require GD;
		if (GD::Image->can('jpeg')) {
			return 1;
		} else {
			return 0;
		}
	};

	sub serverResizesArt(){
		return $canUseGD;
	}
}

sub getResizeCoords {
	my $sourceImageWidth = shift;
	my $sourceImageHeight = shift;
	my $destImageWidth = shift;
	my $destImageHeight = shift;


	my $sourceImageAR = 1.0 * $sourceImageWidth / $sourceImageHeight;
	my $destImageAR = 1.0 * $destImageWidth / $destImageHeight;

	my ($destX, $destY, $destWidth, $destHeight);

	if ($sourceImageAR >= $destImageAR) {
		$destX = 0;
		$destWidth = $destImageWidth;
		$destHeight = $destImageWidth / $sourceImageAR;
		$destY = ($destImageHeight - $destHeight) / 2
	}else{
		$destY = 0;
		$destHeight = $destImageHeight;
		$destWidth = $destImageHeight * $sourceImageAR;
		$destX = ($destImageWidth - $destWidth) / 2
	}

	return ($destX, $destY, $destWidth, $destHeight);
}


1;
