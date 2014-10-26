use warnings;
use strict;
use lib qw(lib);
use Test::More;
use Mojo::Asset::File;
use Mojo::IOLoop;
use Mojolicious::Plugin::Cloudinary;

plan tests => 29;

# test data from
# https://cloudinary.com/documentation/upload_images#request_authentication
my $cloudinary = Mojolicious::Plugin::Cloudinary->new({
                     api_key => '1234567890',
                     api_secret => 'abcd',
                     cloud_name => 'demo',
                 });

{
    is($cloudinary->_api_sign_request({
        timestamp => 1315060510,
        public_id => 'sample',
        file => 'foo bar',
    }), 'c3470533147774275dd37996cc4d0e68fd03cd4f', 'signed request');
}

{
    $cloudinary->_ua->once(start => sub {
        my($ua, $tx) = @_;
        ok($tx, 'upload() generated $tx');
        is($tx->req->url, 'http://api.cloudinary.com/v1_1/demo/image/upload', '...with correct url');
        is($tx->req->param('timestamp'), 1315060510, '...with timestamp');
        is($tx->req->param('public_id'), 'sample', '...with public_id');
        is($tx->req->param('signature'), 'c3470533147774275dd37996cc4d0e68fd03cd4f', '...with signed request');
        is($tx->req->param('file'), 'http://dumm.y/myimage.png', '...with file as url');
    });

    # returns an id. need to use once(start) above to run tests
    $cloudinary->upload({
        file => 'http://dumm.y/myimage.png',
        timestamp => 1315060510,
        public_id => 'sample',
        on_success => sub {},
        on_error => sub {},
    });

    for my $file (
        { file => $0, filename => '10-cloudinary.t' },
        Mojo::Asset::File->new(path => $0),
    ) {
        $cloudinary->_ua->once(start => sub {
            my($ua, $tx) = @_;
            ok($tx, "upload($file) generated tx");
            is($tx->req->param('timestamp'), 1315060510, '...with timestamp');
            is($tx->req->param('public_id'), 'sample', '...with public_id');
            is($tx->req->param('signature'), 'c3470533147774275dd37996cc4d0e68fd03cd4f', '...with signed request');
            for my $part (@{ $tx->req->content->parts }) {
                if(ref($part->asset) eq 'Mojo::Asset::File') {
                    is($part->asset->path, $0, '...$0 in req->content');
                    is($part->headers->content_disposition, 'form-data; name="file"; filename="10-cloudinary.t"', '...filename=$0');
                    is($part->headers->content_type, 'application/octet-stream', '...application/octet-stream');
                }
            }
        });

        # returns an id. need to use once(start) above to run tests
        $cloudinary->upload({
            file => $file,
            timestamp => 1315060510,
            public_id => 'sample',
            on_success => sub {},
            on_error => sub {},
        });
    }
}

{
    $cloudinary->_ua->once(start => sub {
        my($ua, $tx) = @_;
        ok($tx, 'destroy() generated $tx');
        is($tx->req->url, 'http://api.cloudinary.com/v1_1/demo/image/destroy', '...with correct url');
        is($tx->req->param('timestamp'), 1315060510, '...with timestamp');
        is($tx->req->param('public_id'), 'sample', '...with public_id');
        is($tx->req->param('signature'), '9c549a22def9e2690384973d77b3ff79d7b734d7', '...with signed request'); # different key because of "type" is included in POST
    });

    # returns an id. need to use once(start) above to run tests
    $cloudinary->destroy({
        timestamp => 1315060510,
        public_id => 'sample',
        on_success => sub {},
        on_error => sub {},
    });
}

{
    is(
        $cloudinary->url_for('sample.gif'),
        'http://res.cloudinary.com/demo/image/upload/sample.gif',
        'url for sample.gif'
    );
    is(
        $cloudinary->url_for('sample'),
        'http://res.cloudinary.com/demo/image/upload/sample.jpg',
        'url for sample - with default extension .jpg'
    );
    is(
        $cloudinary->url_for('sample', { w => 100, h => 140 }),
        'http://res.cloudinary.com/demo/image/upload/h_140,w_100/sample.jpg',
        'url for sample - with transformation'
    );
}
