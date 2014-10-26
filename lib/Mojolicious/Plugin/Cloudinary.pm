package Mojolicious::Plugin::Cloudinary;

=head1 NAME

Mojolicious::Plugin::Cloudinary - Talk with cloudinary.com

=head1 VERSION

0.0401

=head1 DESCRIPTION

This module lets you interface to L<http://cloudinary.com>. Its primary
target is to be a L<Mojolicious> plugin, but it can also be used as a
generic module - just skip calling L</register>.

=head2 Option expansion

As from 0.04 all methods support the short and long option, meaning
the examples below work the same:

    $self->url_for('billclinton.jpg' => { w => 50 });
    $self->url_for('billclinton.jpg' => { width => 50 });

=head1 SYNOPSIS

=head2 With mojolicious

    package MyWebApp;
    use Mojo::Base 'Mojolicious';

    sub startup {
        my $self = shift;
        $self->plugin('Mojolicious::Plugin::Cloudinary', {
            cloud_name => $str,
            api_key => $str,
            api_secret => $str,
        });
    }

    package MyWebApp::SomeController;

    sub upload {
        my $self = shift;

        $self->render_later;
        $self->cloudinary_upload({
            file => $self->param('upload_param'),
            on_success => sub {
                my $res = shift;
                $self->render_json($res);
            },
            on_error => sub {
                my $res = shift || { error => 'Unknown' };
                $self->render_json($res);
            },
        });
    }

=head2 Standalone

    my $delay = Mojo::IOLoop->delay;
    my $cloudinary = Mojolicious::Plugin::Cloudinary->new(
                         cloud_name => '...',
                         api_key => '...',
                         api_secret => '...',
                     );

    $delay->begin;
    $cloudinary->upload({
        file => { file => $path_to_file },
        on_success => sub {
            # ...
            $delay->end;
        },
        on_error => sub {
            # ...
            $delay->end;
        },
    });

    # let's you do multiple upload() in parallel
    # just call $delay->begin once pr upload()
    # and $delay->end in each on_xxx callback
    $delay->wait;

=head2 url_for() examples

    $cloudinary->url_for('billclinton.jpg', { type => 'facebook' });
    $cloudinary->url_for('billclinton.jpg', { type => 'twitter_name', h => 70, w => 100 });
    $cloudinary->url_for('18913373.jpg', { type => 'twitter_name' });
    $cloudinary->url_for('my-uploaded-image.jpg', { h => 50, w => 50 });
    $cloudinary->url_for('myrawid', { resource_type => 'raw' });

=cut

use Mojo::Base 'Mojolicious::Plugin';
use File::Basename;
use Mojo::UserAgent;
use Mojo::Util qw/ sha1_sum url_escape /;
use Scalar::Util 'weaken';

our $VERSION = eval '0.0401';
our(%SHORTER, %LONGER);
my @SIGNATURE_KEYS = qw/ callback eager format public_id tags timestamp transformation type /;

{
    %LONGER = (
        a => 'angle',
        b => 'background',
        c => 'crop',
        d => 'default_image',
        e => 'effect',
        f => 'fetch_format',
        g => 'gravity',
        h => 'height',
        l => 'overlay',
        p => 'prefix',
        q => 'quality',
        r => 'radius',
        t => 'named_transformation',
        w => 'width',
        x => 'x',
        y => 'y',
    );
    %SHORTER = reverse %LONGER;
}

=head1 ATTRIBUTES

=head2 cloud_name

Your cloud name from L<https://cloudinary.com/console>

=head2 api_key

Your API key from L<https://cloudinary.com/console>

=head2 api_secret

Your API secret from L<https://cloudinary.com/console>

=head2 private_cdn

Your private CDN url from L<https://cloudinary.com/console>.

=head2 js_image

This string will be used as the image src for images constructed by
L</cloudinary_js_image>. The default is "/image/blank.png".

=cut

__PACKAGE__->attr(cloud_name => sub { die 'cloud_name is required in constructor' });
__PACKAGE__->attr(api_key => sub { die 'api_key is required in constructor' });
__PACKAGE__->attr(api_secret => sub { die 'api_secret is required in constructor' });
__PACKAGE__->attr(private_cdn => sub { die 'private_cdn is required in constructor' });
__PACKAGE__->attr(js_image => sub { '/image/blank.png' });
__PACKAGE__->attr(_api_url => sub { 'http://api.cloudinary.com/v1_1' });
__PACKAGE__->attr(_public_cdn => sub { 'http://res.cloudinary.com' });
__PACKAGE__->attr(_ua => sub {
    my $ua = Mojo::UserAgent->new;

    $ua->on(start => sub {
        my($ua, $tx) = @_;

        for my $part (@{ $tx->req->content->parts }) {
            my $content_type = $part->headers->content_type || '';
            $part->headers->remove('Content-Type') if $content_type eq 'text/plain';
        }
    });

    return $ua;
});

=head1 METHODS

=head2 upload

    $self->upload({
        file => $binary_str|$url, # required
        timestamp => $epoch, # time()
        public_id => $str, # optional
        format => $str, # optional
        resource_type => $str, # image or raw. defaults to "image"
        tags => ['foo', 'bar'], # optional
        on_success => sub {
            my($res) = @_;
            # ...
        },
        on_error => sub {
            my($res, $tx) = @_;
            # ...
        },
    });

Will upload a file to L<http://cloudinary.com> using the parameters given
L</cloud_name>, L</api_key> and L</api_secret>. C<$res> in C<on_success>
will be the json response from cloudinary:

    {
        url => $str,
        secure_url => $str,
        public_id => $str,
        version => $str,
        width => $int, # only for images
        height => $int, # only for images
    }

C<$res> for C<on_error> on the other hand can be either C<undef> if there
was an issue connecting/communicating with cloudinary or a an error:

    {
        error => { message: $str },
    }

The C<file> can be:

=over 4

=item * A hash

    { file => 'path/to/image' }

=item * A L<Mojo::Upload> object.

=item * A L<Mojo::Asset> object.

=item * A URL

=back

C<res> in callbacks will be the JSON response from L<http://cloudinary.com>
as a hash ref. It may also be C<undef> if something went wrong with the
actual HTTP POST.

See also L<https://cloudinary.com/documentation/upload_images> and
L<http://cloudinary.com/documentation/upload_images#raw_uploads>.

=cut

sub upload {
    my($self, $args) = @_;
    
    # TODO: transformation, eager
    $args->{'resource_type'} ||= 'image';
    $args->{'timestamp'} ||= time;

    for my $name (qw/ file on_success /) {
        defined $args->{$name}
            or die "Usage: \$self->upload({ $name => ... })";
    }

    if(ref $args->{'tags'} eq 'ARRAY') {
        $args->{'tags'} = join ',', @{ $args->{'tags'} };
    }
    if(UNIVERSAL::isa($args->{'file'}, 'Mojo::Asset')) {
        $args->{'file'} = {
            file => $args->{'file'},
            filename => $args->{'filename'} || basename($args->{'file'}->path),
        };
    }
    elsif(UNIVERSAL::isa($args->{'file'}, 'Mojo::Upload')) {
        $args->{'file'} = {
            file => $args->{'file'}->asset,
            filename => $args->{'file'}->filename,
        };
    }

    $self->_call_api(upload => $args, {
        timestamp => time,
        (map { ($_, $args->{$_}) } grep { defined $args->{$_} } @SIGNATURE_KEYS),
        file => $args->{'file'},
    });
}

=head2 destroy

    $self->destroy({
        public_id => $public_id,
        resource_type => $str, # image or raw. defaults to "image"
        on_success => sub {
            # ...
        },
        on_error => sub {
            my($res, $tx) = @_;
            # ...
        },
    });

Will delete an image from cloudinary, identified by C<$public_id>.
C<on_success> will be called when the image got deleted, while C<on_error>
is called if not: C<$res> can be either C<undef> if there was an issue
connecting/communicating with cloudinary or a an error:

    {
        error => { message: $str },
    }

See also L<https://cloudinary.com/documentation/upload_images#deleting_images>.

=cut

sub destroy {
    my($self, $args) = @_;

    for my $name (qw/ public_id on_success /) {
        defined $args->{$name}
            or die "Usage: \$self->destroy({ $name => ... })";
    }

    $args->{'resource_type'} ||= 'image';

    $self->_call_api(destroy => $args, {
        public_id => $args->{'public_id'},
        timestamp => $args->{'timestamp'} || time,
        type => $args->{'type'} || 'upload',
    });
}

sub _call_api {
    my($self, $action, $args, $post) = @_;
    my $url = join '/', $self->_api_url, $self->cloud_name, $args->{'resource_type'}, $action;
    my $on_error = $args->{'on_error'} || sub {};
    my $on_success = $args->{'on_success'};
    my $headers = { 'Content-Type' => 'multipart/form-data' };

    $post->{'api_key'} = $self->api_key;
    $post->{'signature'} = $self->_api_sign_request($post);

    $self->_ua->post_form($url, $post, $headers, sub {
        my($ua, $tx) = @_;

        if($tx->success) {
            $on_success->($tx->res->json);
        }
        else {
            $on_error->($tx->res->json, $tx);
        }
    });
}

sub _api_sign_request {
    my($self, $args) = @_;
    my @query;

    for my $k (@SIGNATURE_KEYS) {
        push @query, "$k=" .url_escape $args->{$k} if defined $args->{$k};
    }

    $query[-1] .= $self->api_secret;

    sha1_sum join '&', @query;
}

=head2 url_for

    $url_obj = $self->url_for("$public_id.$format", \%args);

This method will return a public URL to the image at L<http://cloudinary.com>.
It will use L</private_cdn> or the public CDN and L</cloud_name> to construct
the URL. The return value is a L<Mojo::URL> object.

Example C<%args>:

    {
        w => 100, # width of image
        h => 150, # height of image
        resource_type => $str, # image or raw. defaults to "image"
        type => $str, # upload, facebook. defaults to "upload"
        secure => $bool, # use private_cdn or public cdn
    }

See also L<http://cloudinary.com/documentation/upload_images#accessing_uploaded_images>
and L<http://cloudinary.com/documentation/image_transformations>.

=cut

sub url_for {
    my $self = shift;
    my $public_id = shift or die 'Usage: $self->url_for($public_id, ...)';
    my $args = shift || {};
    my $format = $public_id =~ s/\.(\w+)// ? $1 : 'jpg';
    my $url = Mojo::URL->new(delete $args->{'secure'} ? $self->private_cdn : $self->_public_cdn);

    $url->path(join '/', grep { length }
        $self->cloud_name,
        $args->{'resource_type'} || 'image',
        $args->{'type'} || 'upload',
        join(',', map { ($SHORTER{$_} || $_) .'_' .$args->{$_} } sort keys %$args),
        "$public_id.$format",
    );

    return $url;
}

=head2 register

Adds the helpers to your controller:

=over 4

=item * cloudinary_upload

=item * cloudinary_destroy

See L</upload>.

=item * cloudinary_url_for

See L</url_for>.

=item * cloudinary_image

    $str = $c->cloudinary_image($public_id, $url_for_args, $image_args);

This will use L<Mojolicious::Plugin::TagHelpers/image> to create an image
tag where "src" is set to a cloudinary image. C<$url_for_args> are passed
on to L</url_for> and C<$image_args> are passed on to
L<Mojolicious::Plugin::TagHelpers/image>.

=item * cloudinary_js_image

    $str = $c->cloudinary_js_image($public_id, $url_for_args);

About the same as L</cloudinary_image>, except it creates an image which can
handled by the cloudinary jQuery plugin which you can read more about here:
L<http://cloudinary.com/blog/cloudinary_s_jquery_library_for_embedding_and_transforming_images>

Example usage:

    $c->cloudinary_js_image(1234567890 => {
        width => 115,
        height => 115,
        crop => 'thumb',
        gravity => 'faces',
        radius => '20',
    });

...will produce:

    <img src="/image/blank.png"
        class="cloudinary-js-image"
        alt="1234567890"
        data-src="1234567890"
        data-width="115"
        data-height="135"
        data-crop="thumb"
        data-gravity="faces"
        data-radius="20">

Note: The "class" and "alt" attributes are fixed for now.

=back

=cut

sub register {
    my($self, $app, $config) = @_;

    for my $k (keys %{ $config || {} }) {
        $self->$k($config->{$k}) if exists $config->{$k};
    }

    $app->helper(cloudinary_upload => sub {
        my $c = shift;
        $self->upload(@_);
    });
    $app->helper(cloudinary_destroy => sub {
        my $c = shift;
        $self->destroy(@_);
    });
    $app->helper(cloudinary_url_for => sub {
        my($c, $public_id, $args) = @_;
        my $scheme = $c->req->url->scheme || '';

        if(not defined $args->{'secure'} and $scheme eq 'https') {
            $args->{'secure'} = 1;
        }

        return $self->url_for($public_id, $args);
    });
    $app->helper(cloudinary_image => sub {
        my($c, $public_id, $args, $image_args) = @_;
        my $scheme = $c->req->url->scheme || '';

        if(not defined $args->{'secure'} and $scheme eq 'https') {
            $args->{'secure'} = 1;
        }

        return $c->image($self->url_for($public_id, $args), alt => $public_id, %$image_args);
    });
    $app->helper(cloudinary_js_image => sub {
        my($c, $public_id, $args) = @_;
        my $scheme = $c->req->url->scheme || '';

        if(not defined $args->{'secure'} and $scheme eq 'https') {
            $args->{'secure'} = 1;
        }

        return $c->image(
            $self->js_image,
            'alt' => $public_id,
            'class' => 'cloudinary-js-image',
            'data-src' => $public_id,
            map {
                my $k = $LONGER{$_} || $_;
                ("data-$k" => $args->{$_})
            } keys %$args
        );
    });
}

=head1 COPYRIGHT & LICENSE

See L<Oppstarter>

=head1 AUTHOR

Jan Henning Thorsen - jan.henning@oppstarter.no

=cut

1;
